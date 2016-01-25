# Refactoring status: 100%
_ = require 'underscore-plus'

{CompositeDisposable} = require 'atom'
Base = require './base'
{moveCursorLeft} = require './utils'
settings = require './settings'
{CurrentSelection, Select} = {}

class OperationStack
  constructor: (@vimState) ->
    {@editor} = @vimState
    CurrentSelection ?= Base.getClass('CurrentSelection')
    Select ?= Base.getClass('Select')
    @reset()

  subscribe: (args...) ->
    @subscriptions.add args...

  run: (klass, properties) ->
    klass = Base.getClass(klass) if _.isString(klass)
    unless klass
      throw new Error("Invalid operation, can't run.")
    try
      #  To support, `dd`, `cc` and a like.
      if (@peekTop()?.constructor is klass)
        klass = Base.getClass('MoveToRelativeLine')
      operation = new klass(@vimState, properties)
      if (@vimState.isMode('visual') and _.isFunction(operation.select)) or
          (@isEmpty() and operation.instanceof('TextObject')) # when TextObject invoked directly
        @stack.push(new Select(@vimState))
      @stack.push(operation)
      if @vimState.isMode('visual') and operation.instanceof('Operator')
        @stack.push(new CurrentSelection(@vimState))

      @processing = true
      @process()
    catch error
      @vimState.reset()
      unless error.instanceof?('OperationAbortedError')
        throw error
    finally
      @processing = false

  isProcessing: ->
    @processing

  process: ->
    if @stack.length > 2
      throw new Error('Operation stack length exceeds 2')

    if @stack.length > 1
      try
        operation = @stack.pop()
        @peekTop().setTarget(operation)
      catch error
        if error.instanceof?('OperatorError')
          @vimState.activate('reset')
          return
        else
          throw error

    unless @peekTop().isComplete()
      if @vimState.isMode('normal') and @peekTop().instanceof?('Operator')
        @vimState.activate('operator-pending')
    else
      @operation = @stack.pop()
      @vimState.emitter.emit 'will-execute-operation', @operation
      @execute()

  suspendExecute: ->
    @executionSuspended = true

  unsuspendExecute: ->
    @executionSuspended = false

  isExecuteSuspended: ->
    @executionSuspended

  execute: ->
    return if @isExecuteSuspended()
    execution = @operation.execute()
    finalize = =>
      @vimState.emitter.emit 'did-execute-operation', @operation
      @record(@operation) if @operation.isRecordable()
      @finish()

    if execution instanceof Promise
      execution.then -> finalize()
    else
      finalize()

  cancel: ->
    unless @vimState.isMode('visual') or @vimState.isMode('insert')
      @vimState.activate('reset')
    @finish()

  finish: ->
    @vimState.emitter.emit 'did-finish-operation'
    if @vimState.isMode('normal')
      unless @editor.getLastSelection().isEmpty()
        if settings.get('throwErrorOnNonEmptySelectionInNormalMode')
          operationName = @operation.constructor.name
          message = "Selection is not empty in normal-mode: #{operationName}"
          if @operation.target?
            message += ", target= #{@operation.target.constructor.name}"
          throw new Error(message)
        else
          @editor.clearSelections()

      # Ensure Cursor is NOT at EndOfLine position
      for cursor in @editor.getCursors() when cursor.isAtEndOfLine()
        moveCursorLeft(cursor, {preserveGoalColumn: true})
    @operation = null
    @vimState.refreshCursors()
    @vimState.reset()

  peekTop: ->
    _.last @stack

  reset: ->
    @stack = []
    @executionSuspended = false
    @subscriptions?.dispose()
    @subscriptions = new CompositeDisposable

  destroy: ->
    @subscriptions?.dispose()
    {@stack, @subscriptions} = {}

  isEmpty: ->
    @stack.length is 0

  record: (@recorded) ->

  getRecorded: ->
    @recorded

module.exports = OperationStack
