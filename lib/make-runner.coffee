cp = require 'child_process'
path = require 'path'
fs = require 'fs-plus'
readline = require 'readline'
{$} = require 'atom-space-pen-views'

MakeRunnerView = require './make-runner-view'

module.exports =
  #
  # Lock flag for running make processes (to avoid running make multiple times concurrently)
  #
  makeRunning: null

  #
  # Current exit event listener
  #
  makeCurrentExitHandler: null

  #
  # Make output panel
  #
  makeRunnerPanel: null
  makeRunnerView: null

  #
  # Write the status of the make target to the status bar.
  #
  updateStatus: (message) ->
    @statusBarTile?.destroy()
    statusBar = document.querySelector("status-bar")
    @statusBarTile = statusBar?.addLeftTile(priority: 10, item: $ "<span>Make: #{message}</span>")

  #
  # Clear the make result from the status bar.
  #
  clearStatus: ->
    @statusBarTile?.destroy()

  #
  # Attach the run command.
  #
  activate: (state) ->
    atom.commands.add 'atom-workspace', 'make-runner:run', => @run()
    atom.commands.add 'atom-workspace', 'make-runner:abort', => @abort()
    atom.commands.add 'atom-workspace', 'make-runner:toggle', => @toggle()
    atom.commands.add 'atom-workspace', 'core:cancel', => @makeRunnerPanel?.hide()
    @makeRunnerView = new MakeRunnerView state.makeRunnerViewState
    @makeRunnerPanel = atom.workspace.addBottomPanel(item: @makeRunnerView, visible: false, className: 'atom-make-runner tool-panel panel-bottom')

  #
  # Show/hide the make pane without re-running make
  #
  toggle: ->
    if @makeRunnerPanel.isVisible()
      @makeRunnerPanel.hide()
    else
      @makeRunnerPanel.show()

  #
  # Kill make if it is currently running
  #
  abort: ->
    if @makeRunning
      @makeRunning.kill 'SIGKILL'
      @makeRunning.removeListener 'close', @makeCurrentExitHandler
      @makeCurrentExitHandler = (code, signal) => @makeAbortHandler(code, signal)
      @makeRunning.on 'close', @makeCurrentExitHandler
      @updateStatus "aborting make..."

  #
  # Run the configured make target.
  #
  run: ->
    # guard against launching make while it is still running
    if @makeRunning
      if atom.config.get 'make-runner.killAndRestart'
        @makeRunning.kill 'SIGKILL'
        @updateStatus "restarting make..."
      return

    @isError = false

    target = atom.config.get 'make-runner.buildTarget'

    # figure out number of concurrent make jobs
    if 'JOBS' in process.env
      jobs = process.env.JOBS
    else
      jobs = require('os').cpus().length

    # Check if the active item is a text editor
    editor = atom.workspace.getActiveTextEditor()
    return unless editor?

    make_path = editor.getPath()

    unless make_path?
      @updateStatus "file not saved, nowhere to search for Makefile"

      setTimeout (=>
        @clearStatus()
      ), 3000

      return

    while not fs.existsSync "#{make_path}/Makefile"
      previous_path = make_path
      make_path = path.join make_path, '..'

      if make_path is previous_path
        @updateStatus "no makefile found"

        setTimeout (=>
          @clearStatus()
        ), 3000

        return

    # add number of jobs and possible the make target argument
    args = ['-j', jobs]
    if target?.length
      args.push target

    # spawn make child process
    @updateStatus "running make..."
    @makeRunnerView.clear()
    @makeRunnerPanel.show()
    @makeRunning = make = cp.spawn 'make', args, { cwd: make_path }

    # Use readline to generate line input from raw data
    stdout = readline.createInterface { input: make.stdout, terminal: false }
    stderr = readline.createInterface { input: make.stderr, terminal: false }

    stdout.on 'line',  (line) =>
      @makeRunnerView.printOutput [ $('<span>').text line ]

    stderr.on 'line',  (line) =>
      # search for file:line:col: references
      html_line = null
      line.replace /^([^:]+):(\d+):(\d+):(.*)$/, (match, file, row, col, errormessage) =>
        html_line = [
          $('<a>')
            .text "#{file}:#{row}:#{col}"
            .attr 'href', '#'
            .on 'click', (e) =>
              e.preventDefault()

              # load file, but check if it is already open in any of the panes
              loading = atom.workspace.open file, { searchAllPanes: true }
              loading.then (editor) =>
                editor.setCursorBufferPosition [row-1, col-1],
          $('<span>').text errormessage
        ]

        @isError = errormessage.indexOf(" error:") is 0

      # no file:row:col marker found, outputting as plain text
      html_line ?= [ $('<span>').text line ]

      if @isError
        @makeRunnerView.printError html_line
      else
        @makeRunnerView.printWarning html_line

    # fire this off when the make process comes to an end
    @makeCurrentExitHandler = (code, signal) => @makeExitHandler(code, signal)
    make.on 'close', @makeCurrentExitHandler

  #
  # if enabled in the configuration, hide the make output pane
  #
  hideMakePane: ->
    if atom.config.get 'make-runner.hidePane'
      setTimeout (=>
        @makeRunnerPanel.hide()
      ), atom.config.get 'make-runner.hidePaneDelay'

  #
  # Regular make exit handler
  #
  makeExitHandler: (code, signal) ->
    @makeRunning = null

    # the previous make process was killed successfully
    if signal is 'SIGKILL'
      @run()
      return

    # make exited on its own
    if code is 0
      @updateStatus 'succeeded'
      @hideMakePane
    else
      @updateStatus "failed with code #{code}"

    setTimeout (=>
      @clearStatus()
    ), 3000

  #
  # make abort exit handler
  #
  makeAbortHandler: (code, signal) ->
    @makeRunning = null

    @updateStatus 'aborted'

    setTimeout (=>
      @clearStatus()
    ), 3000


  #
  # Deactivate the package.
  #
  deactivate: ->
    @clearStatus()
    @makeRunnerView.destroy()

  serialize: ->
    makeRunnerViewState: @makeRunnerView.serialize()

  #
  # Set the default build target.
  #
  config:
    buildTarget:
      type: 'string'
      default: ''
    killAndRestart:
      type: 'boolean'
      default: false
      description: 'Kill and restart the current make process rather than block if make is running.'
    hidePane:
      type: 'boolean'
      default: false
      description: 'Hide make panel if execution is successful.'
    hidePaneDelay:
      type: 'integer'
      default: 3000
      min:0
