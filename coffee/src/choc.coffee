# Choc: An Experiment in Learnable Programming
#
# References: 
# 
#
{puts,inspect} = require("util"); pp = (x) -> puts inspect(x, null, 1000)
esprima = require("esprima")
escodegen = require("escodegen")
esmorph = require("esmorph")
estraverse = require('../../lib/estraverse')
_ = require("underscore")
readable = require("./readable")
debug = require("debug")("choc")
deep = require("deep")

# TODOs 
# * return a + b in a function ReturnStatement placement
# * if statements - hoist conditional into tmp and put a trace before calling the if
# * While statement placement - ending part
# * add a trace at the very last step that says 'done'
# * function returns - i think we're going to need to transform every ReturnStatement to hoist its argument into a variable - then give the language for that variable and pause on that line right before you return it
# * function calls on the line
# * return syntax errors for parsing in a digestable way

Choc = 
  VERSION: "0.0.1"
  TRACE_FUNCTION_NAME: "__choc_trace"
  PAUSE_ERROR_NAME: "__choc_pause"
  EXECUTION_FINISHED_ERROR_NAME: "__choc_finished"

# Given string nodeType, returns true if the nodeType is (loosely, not strictly)
# a statement (e.g. unit of interest). Returns false otherwise

PLAIN_STATEMENTS = [
 'BreakStatement', 'ContinueStatement', 'DoWhileStatement',
 'DebuggerStatement', 'EmptyStatement', 'ExpressionStatement',
 'ForStatement', 'ForInStatement',  'LabeledStatement',
 'SwitchStatement', 'ThrowStatement', 'TryStatement',
 'WithStatement',
 'VariableDeclaration'
]

HOIST_STATEMENTS = [
  'ReturnStatement', 'WhileStatement', 'IfStatement',
]

ALL_STATEMENTS = PLAIN_STATEMENTS.concat(HOIST_STATEMENTS)
isStatement      = (nodeType) -> _.contains(ALL_STATEMENTS, nodeType)
isPlainStatement = (nodeType) -> _.contains(PLAIN_STATEMENTS, nodeType)
isHoistStatement = (nodeType) -> _.contains(HOIST_STATEMENTS, nodeType)

# varInit: e.g. { type: 'Literal', value: 1 } 
generateVariableDeclaration = (varInit) ->
  identifier = "__choc_var_" + Math.floor(Math.random() * 1000000) # TODO - real uuid
  { 
   type: 'VariableDeclaration'
   kind: 'var' 
   declarations: [ { 
     type: 'VariableDeclarator',
     id: { type: 'Identifier', name:  identifier },
     init: varInit
     } 
   ]
  }

generateAnnotatedSource = (source) ->

  try
    tree = esprima.parse(source, {range: true, loc: true})
  catch e
    error = new Error("choc source parsing error")
    error.original = e
    throw error
  # puts inspect tree, null, 20

  candidates = []

  estraverse.traverse tree, {
    enter: (node, parent, element) ->
      # puts "enter:"
      # puts inspect node
      # puts inspect parent
      # puts inspect element
      if isStatement(node.type) 
        candidates.push({node: node, parent: parent, element: element})
  }

  hoister = 
    'IfStatement': 'test'
    'WhileStatement': 'test' 
    'ReturnStatement': 'argument'

  for candidate in candidates
    node = candidate.node
    parent = candidate.parent
    element = candidate.element 

    parentPathAttribute = element.path[0]
    parentPathIndex     = element.path[1]
    parent.__choc_offset = 0 unless parent.hasOwnProperty("__choc_offset")

    nodeType = node.type
    line = node.loc.start.line
    range = node.range
    pos = node.range[1]

    messagesString = readable.readableNode(node)


    if isStatement(nodeType)
      # create the call to the trace function here. It's a lot easier to write
      # the string and then call esprima.parse for now. But probably would get a
      # performance boost if you just wrote the raw parse tree here. That said,
      # composing 'messagesString' is tricky so it might just be easier to parse
      # forever if it's fast enough. 
      signature = """
      #{Choc.TRACE_FUNCTION_NAME}({ lineNumber: #{line}, range: [ #{range[0]}, #{range[1]} ], type: '#{nodeType}', messages: #{messagesString} });
      """
      traceTree =  esprima.parse(signature).body[0]
      newPosition = null

      if isHoistStatement(nodeType)
      #if false
        # pull test expresion out
        originalExpression = node[hoister[nodeType]]

        # generate our new pre-variable
        newCodeTree = generateVariableDeclaration(originalExpression)
        parent[parentPathAttribute].splice(parentPathIndex + parent.__choc_offset, 0, newCodeTree)

        # replace it with the name of our variable
        newVariableName = newCodeTree.declarations[0].id.name
        node[hoister[node.type]] = { type: 'Identifier', name: newVariableName }
        parent.__choc_offset = parent.__choc_offset + 1

        # ah - what if we populated our own choc_tracer here? then we maintain our line numbers
        if _.isNumber(parentPathIndex)
          newPosition = parentPathIndex + parent.__choc_offset
        else 
          puts "WARNING: no parent idx"

      # TODO else or not else?
      # else if isPlainStatement(nodeType)

      if isPlainStatement(nodeType)
        if _.isNumber(parentPathIndex)
          newPosition = parentPathIndex + parent.__choc_offset + 1
        else 
          puts "WARNING: no parent idx"


      # if there are several siblings being set, then we need to account for our new location to be incremented by one per addition
      parent[parentPathAttribute].splice(newPosition, 0, traceTree)
      parent.__choc_offset = parent.__choc_offset + 1

  escodegen.generate(tree, format: { compact: false } )

# TODO - use an LRU memoize if you're planning on doing a lot of editing
generateAnnotatedSourceM = _.memoize(generateAnnotatedSource)

class Tracer
  constructor: (options={}) ->
    @frameCount = 0
    @onMessages = () ->
    @clearTimeline()

  clearTimeline: () ->
    @timeline = {
      steps: []
      stepMap: {}
      maxLines: 0
    }

  trace: (opts) =>
    @frameCount = 0
    (info) =>
      @timeline.steps[@frameCount] = {lineNumber: info.lineNumber}
      @timeline.stepMap[@frameCount] ||= {}
      @timeline.stepMap[@frameCount][info.lineNumber - 1] = true
      @timeline.maxLines = Math.max(@timeline.maxLines, info.lineNumber)
      info.frameNumber = @frameCount # todo revise this language

      @frameCount = @frameCount + 1
      # console.log("count:  #{@frameCount}/#{opts.count} type: #{info.type}")
      if @frameCount >= opts.count
        @onMessages(info.messages)
        error = new Error(Choc.PAUSE_ERROR_NAME)
        error.info = info
        throw error

noop = () -> 

scrub = (source, count, opts) ->
  onFrame     = opts.onFrame     || noop
  beforeEach  = opts.beforeEach  || noop
  afterEach   = opts.afterEach   || noop
  afterAll    = opts.afterAll    || noop
  onTimeline  = opts.onTimeline  || noop
  onMessages  = opts.onMessages  || noop
  onCodeError = opts.onCodeError || noop
  locals      = opts.locals      || {}

  newSource   = generateAnnotatedSource(source)
  # newSource   = generateAnnotatedSourceM(source)
  debug(newSource)

  tracer = new Tracer()
  tracer.onMessages = onMessages
  tracer.onTimeline = onTimeline

  executionTerminated = false
  try
    beforeEach()

    # create a few functions to be used by the eval'd source
    __choc_trace         = tracer.trace(count: count)
    __choc_first_message = (messages) -> messages[0]?.message || "TODO"

    # add our own local vars
    locals.Choc = Choc

    # define any user-given locals as a string for eval'ing
    localsStr = _.map(_.keys(locals), (name) -> "var #{name} = locals.#{name};").join("; ")
  
    # http://perfectionkills.com/global-eval-what-are-the-options/
    console.log(newSource)
    eval(localsStr + "\n" + newSource)

    # if you make it here without an exception, execution finished
    executionTerminated = true
    console.log("execution terminated")
  catch e

    # throwing a Choc.PAUSE_ERROR_NAME is how we pause execution (for now)
    # the most obvious consequence of this is that you can't have a catch-all
    # exception handler in the code you wish to trace
    if e.message == Choc.PAUSE_ERROR_NAME
      onFrame(e.info)
    else
      throw e
  finally
    # call afterEach after each frame no matter what happens. E.g. if we are
    # drawing a picture, we want to be able to update the canvas even if we
    # paused execution halfway through
    afterEach()

    # if no exceptions were raised then we've successfully run our whole
    # program. Call back to the client and let them know how many steps we've
    # taken and give them the tracer's timeline
    if executionTerminated
      afterAll({frameCount: tracer.frameCount})
      onTimeline(tracer.timeline)

exports.scrub = scrub
exports.generateAnnotatedSource = generateAnnotatedSource
