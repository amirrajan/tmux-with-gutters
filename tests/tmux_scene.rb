# Helper for rendering a tmux window and asserting on what is actually drawn.
#
# Pane borders are not part of any pane's grid, so capture-pane on a pane never
# shows them. A scene is rendered by an inner tmux server which is then
# attached inside a pane of an outer tmux server; capturing the outer pane
# gives the whole client scene as drawn by screen-redraw.c. This is the same
# approach as the shell test screen-redraw-tiled.sh, wrapped up so that a test
# only has to describe the window and the expected picture.
#
# Usage:
#
#   scene = TmuxScene.new(width: 10, height: 4, conf: <<~CONF)
#     set -w -g pane-border-lines single
#   CONF
#   scene.start
#   scene.split_window('-h')
#   scene.fill_panes
#   scene.capture
#   assert_scene scene, <<~WANT
#     ┌───┐┌───┐
#     ...
#   WANT

require 'open3'
require 'tmpdir'

class TmuxScene
  # tmux needs a usable PATH for its default shell and for the commands run
  # inside panes; the test runner clears the environment with env -i.
  CHILD_ENV = {
    'PATH' => '/bin:/usr/bin',
    'TERM' => 'screen',
    'LC_ALL' => 'C.UTF-8'
  }.freeze

  # Shell run inside every pane. The prompt is emptied so that the fill is the
  # only pane content.
  SHELL = '/bin/zsh'.freeze

  # Fills a pane with exactly rows*cols dots. stty reports that pane's own pty
  # size, so the same command fills a pane of any size. The typed command line
  # wraps over several rows, so the fill scrolls the pane and ends on its last
  # cell, leaving every row full of dots. The shell is then replaced by sleep,
  # because returning to the shell would emit a newline for the next prompt and
  # scroll a row of dots away.
  FILL = 'set -- $(stty size); printf "%$(($1*$2))s" "" | tr " " .; ' \
         'exec sleep 1000'.freeze

  # Default seconds to wait for tmux to settle after a command. Each scene can
  # override it, because how long a scene needs depends on what it does: an
  # ordinary redraw is quick, while putting a pane into a mode is not. The
  # environment variable is a convenience for sweeping the whole suite.
  DEFAULT_DELAY = Float(ENV.fetch('SCENE_DELAY', '0.05'))

  attr_reader :width, :height, :captured, :delay

  def initialize(width:, height:, conf: '', tmux: nil, delay: DEFAULT_DELAY)
    @width = width
    @height = height
    @delay = delay
    @tmux = tmux || ENV['TEST_TMUX'] || File.expand_path('../tmux', __dir__)
    @conf = conf
    @captured = nil
    @inner_socket = "sceneB#{Process.pid}"
    @outer_socket = "sceneA#{Process.pid}"
    @started = false
    @attached = false
  end

  # True when this platform can run the scene at all.
  def self.supported?
    File.executable?(SHELL)
  end

  # Start the inner server with the given config and one window of the wanted
  # size. status off and window-size manual keep the geometry fixed.
  def start
    @conf_path = File.join(Dir.tmpdir, "tmux-scene-#{Process.pid}.conf")
    File.write(@conf_path, <<~BASE + @conf)
      set -g status off
      set -g window-size manual
      set -g default-shell #{SHELL}
    BASE

    kill_servers
    @started = true
    at_exit { stop }

    inner('new', '-d', '-x', width.to_s, '-y', height.to_s)
    inner('resizew', '-x', width.to_s, '-y', height.to_s)
    settle(1)
    self
  end

  # Split the current window, e.g. split_window('-h').
  def split_window(*args)
    inner('split-window', *args)
    settle(1)
    self
  end

  # Run a tmux command against the inner server, e.g. set('-w', '-g',
  # 'pane-border-lines', 'double').
  def set(*args)
    inner('set', *args)
    self
  end

  # Run any other tmux command against the inner server, e.g.
  # cmd('select-pane', '-t0'). Returns the command output.
  def cmd(*args)
    inner(*args)
  end

  # Fill every pane with dots. synchronize-panes sends the setup to all panes at
  # once, so this works whatever the layout is.
  def fill_panes
    inner('setw', 'synchronize-panes', 'on')
    send_line("export PROMPT=''")
    send_line('reset')
    settle(1)
    send_line(FILL)
    settle(2)
    inner('setw', 'synchronize-panes', 'off')
    self
  end

  # Refill every pane after something has changed its size. The panes are no
  # longer running a shell by then (fill_panes replaces it with sleep), so each
  # one is respawned with the fill command instead of being typed into. tmux
  # runs the command through a shell, and stty reports the pane's new size.
  def refill_panes
    pane_indexes.each do |index|
      inner('respawn-pane', '-k', "-t:.#{index}", FILL)
    end
    settle(2)
    self
  end

  # The pane indexes of the current window, in list-panes order.
  def pane_indexes
    inner('list-panes', '-F', '#{pane_index}').split("\n")
  end

  # The index of the active pane.
  def active_pane
    inner('display', '-p', '#{pane_index}')
  end

  # Make a pane active, then optionally move from it, e.g.
  # select_pane('-t0') or select_pane('-R').
  def select_pane(*args)
    inner('select-pane', *args)
    self
  end

  # Leave every pane empty instead of filling it, for scenes where the pane
  # content would only get in the way. The panes are respawned with a command
  # that draws nothing and does not exit.
  def blank_panes
    pane_indexes.each do |index|
      inner('respawn-pane', '-k', "-t:.#{index}", 'exec sleep 1000')
    end
    settle(1)
    self
  end

  # Attach the inner server inside an outer pane of the same size, so that it
  # has a client and actually draws. Idempotent: a test that needs a client
  # before it runs a command (display-panes, for example) can call this and
  # then capture later.
  def attach
    return self if @attached

    outer('new', '-d', '-x', width.to_s, '-y', height.to_s)
    outer('set', '-g', 'status', 'off')
    outer('set', '-g', 'window-size', 'manual')
    outer('set', '-g', 'default-terminal', 'tmux-256color')
    outer('send', '-l', "#{@tmux} -L#{@inner_socket} -f#{@conf_path} attach")
    outer('send', 'Enter')
    settle(2)
    @attached = true
    self
  end

  # Show the pane numbers and leave them up, waiting for a key that never
  # comes, so that the overlay can be captured. Needs a client, so the scene is
  # attached first.
  def display_panes
    attach
    inner('display-panes', '-d', '0')
    settle(1)
    self
  end

  # Capture what is drawn. Returns the scene as a string, one line per row.
  def capture
    attach
    @captured = outer('capturep', '-p')
    @captured += "\n" unless @captured.empty? || @captured.end_with?("\n")
    @captured
  end

  # Capture with the escape sequences left in, so that colours can be checked.
  def capture_escapes
    attach
    text = outer('capturep', '-pe')
    text += "\n" unless text.empty? || text.end_with?("\n")
    text
  end

  # Pane geometry as a string, one line per pane, in list-panes order:
  # "index left top width height".
  def geometry
    inner('list-panes', '-F',
          '#{pane_index} #{pane_left} #{pane_top} ' \
          '#{pane_width} #{pane_height}')
  end

  # A one line summary of the window, used in failure messages.
  def window_summary
    inner('display', '-p',
          '#{window_width}x#{window_height} panes=#{window_panes}')
  end

  # The values of the options a border test cares about, for failure messages.
  # An option that does not exist is reported rather than raised, so that a
  # failure report still prints when an option has been removed.
  def option_summary
    %w[pane-border-lines pane-border-status].map do |name|
      value =
        begin
          inner('show', '-w', '-g', '-v', name)
        rescue RuntimeError
          '(unknown)'
        end
      "#{name}=#{value}"
    end.join(' ')
  end

  def alive?
    inner('display-message', '-p', 'alive') == 'alive'
  end

  def stop
    return unless @started

    @started = false
    kill_servers
    File.delete(@conf_path) if @conf_path && File.exist?(@conf_path)
  end

  # Wait for n round trips worth of settling.
  def settle(n = 1)
    sleep(delay * n)
  end

  private

  def send_line(text)
    inner('send', '-l', text)
    inner('send', 'Enter')
  end

  def inner(*args)
    run(@tmux, "-L#{@inner_socket}", "-f#{@conf_path}", *args)
  end

  def outer(*args)
    run(@tmux, "-L#{@outer_socket}", '-f/dev/null', *args)
  end

  def kill_servers
    [@inner_socket, @outer_socket].each do |socket|
      Open3.capture2e(CHILD_ENV, @tmux, "-L#{socket}", 'kill-server',
                      unsetenv_others: true)
    end
  end

  # Run a tmux command and return its output with the trailing newline removed.
  # A failing tmux command is a test error, not a quiet empty string.
  def run(*args)
    out, status = Open3.capture2e(CHILD_ENV, *args, unsetenv_others: true)
    unless status.success?
      raise "command failed: #{args.join(' ')}\n#{out}"
    end

    out.sub(/\n\z/, '')
  end
end

# Assertions for scenes. Every failure reports the whole picture and the whole
# geometry table, not just the first difference, because a border change moves
# several things at once and the surrounding context is what makes the failure
# readable.
module SceneAssertions
  # Every glyph a pane border can be drawn with, in any pane-border-lines style.
  BORDER_GLYPHS = /[─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬━┃┏┓┗┛┣┫┳┻╋|+-]/.freeze

  def assert_scene(scene, expected, message = 'rendered scene does not match')
    assert_equal expected, scene.captured, scene_report(scene, expected, message)
  end

  # Assert that two scenes put their borders in exactly the same cells. Anything
  # that is not a border glyph is blanked out first, so pane content and
  # overlays are ignored and only the border skeleton is compared.
  def assert_same_borders(before, after, message = 'borders moved')
    want = border_skeleton(before)
    got = border_skeleton(after)
    return if want == got

    report = [
      message, '',
      'borders in the first scene:', boxed(want), '',
      'borders in the second scene:', boxed(got), '',
      'first scene in full:', boxed(before), '',
      'second scene in full:', boxed(after)
    ].join("\n")
    flunk report
  end

  # Replace everything that is not a border glyph with a space, keeping the
  # shape of the scene. Trailing spaces are dropped because capture-pane
  # already trims them, so a row whose last border is followed by pane content
  # in one scene and by nothing in the other still compares equal.
  def border_skeleton(text)
    text.split("\n", -1).map { |line|
      line.gsub(/./) { |c| BORDER_GLYPHS.match?(c) ? c : ' ' }.rstrip
    }.join("\n")
  end

  # Assert a whole layout from one picture: the panes are where the picture
  # says they are, and the scene is drawn exactly as the picture shows.
  #
  # The pane rectangles are worked out from the picture rather than written out
  # again as numbers, so there is a single source of truth and the two cannot
  # drift apart. Every run of pane cells in the picture must be a rectangle, and
  # the rectangles must match what tmux reports, compared in reading order
  # rather than by pane index, since index order depends on how the layout was
  # built.
  #
  # pane_char is the character the panes are filled with.
  def assert_layout(scene, picture, pane_char: '.')
    want = picture_rectangles(picture, pane_char)
    got = geometry_rectangles(scene.geometry)

    unless want == got
      flunk layout_report(scene, picture, want, got)
    end

    assert_scene scene, picture
  end

  # Assert the background colour of every cell, as a picture.
  #
  # colours maps an SGR background parameter to the character to use for it, so
  # a test can say that cells with background 41 are the active pane, cells with
  # 44 are an inactive pane and cells with the default background are border.
  # Anything not in the map becomes a question mark.
  def assert_style_map(scene, expected, colours)
    got = style_map(scene.capture_escapes, colours)
    return if got == expected

    report = [
      'background colours do not match', '',
      'expected:', boxed(expected), '',
      'actual:', boxed(got), '',
      'key:', colours.map { |code, char| "  #{char} = SGR #{code}" }.join("\n"),
      '', "window: #{scene.window_summary}"
    ].join("\n")
    flunk report
  end

  # Reduce an escaped capture to one character per cell, chosen by the
  # background colour in force when the cell was written.
  def style_map(text, colours)
    background = 49
    out = +''

    text.scan(/\e\[([0-9;]*)m|([^\e])/) do |sgr, char|
      if sgr
        sgr.split(';').each do |param|
          value = param.to_i
          background = value if (40..49).cover?(value) || (100..107).cover?(value)
        end
      elsif char == "\n"
        out << char
      else
        out << (colours[background] || '?')
      end
    end

    out
  end

  # Assert only that the panes are where the picture says, without comparing
  # the drawn scene. For cases where the picture cannot be compared directly,
  # such as an overlay drawn on top of the panes.
  def assert_pane_rectangles(scene, picture, pane_char: '.')
    want = picture_rectangles(picture, pane_char)
    got = geometry_rectangles(scene.geometry)
    return if want == got

    flunk layout_report(scene, picture, want, got)
  end

  def assert_geometry(scene, expected, message = 'pane geometry does not match')
    assert_equal expected.chomp, scene.geometry,
                 scene_report(scene, nil, message, expected)
  end

  private

  # Find the pane rectangles in a picture: every maximal run of pane cells must
  # be a solid rectangle. Returns [left, top, width, height] in reading order.
  def picture_rectangles(picture, pane_char)
    rows = picture.split("\n")
    seen = {}
    rects = []

    rows.each_with_index do |line, y|
      line.each_char.with_index do |char, x|
        next if char != pane_char || seen[[x, y]]

        width = 0
        width += 1 while line[x + width] == pane_char
        height = 0
        height += 1 while rows[y + height]&.slice(x, width) == pane_char * width

        (y...y + height).each do |ry|
          (x...x + width).each { |rx| seen[[rx, ry]] = true }
        end
        rects << [x, y, width, height]
      end
    end

    rects.sort_by { |x, y, _, _| [y, x] }
  end

  # tmux geometry lines ("index left top width height") as rectangles in the
  # same shape and order as picture_rectangles.
  def geometry_rectangles(text)
    text.split("\n").map { |line|
      _index, left, top, width, height = line.split.map(&:to_i)
      [left, top, width, height]
    }.sort_by { |x, y, _, _| [y, x] }
  end

  def layout_report(scene, picture, want, got)
    rows = ['pane rectangles do not match the picture', '']
    rows << 'wanted picture:' << boxed(picture) << ''
    rows << 'actual scene:' << boxed(scene.captured) << ''
    rows << 'wanted rectangles (left top width height), from the picture:'
    rows << indent(want.map { |r| r.join(' ') }.join("\n")) << ''
    rows << 'actual rectangles (left top width height), from tmux:'
    rows << indent(got.map { |r| r.join(' ') }.join("\n")) << ''
    rows << "window: #{scene.window_summary}"
    rows << "options: #{scene.option_summary}"
    rows.join("\n")
  end

  def scene_report(scene, expected_scene, message, expected_geometry = nil)
    lines = [message, '']

    if expected_scene
      lines << 'expected scene:' << boxed(expected_scene) << ''
    end
    lines << 'actual scene:' << boxed(scene.captured) << ''

    if expected_geometry
      lines << 'expected geometry (index left top width height):'
      lines << indent(expected_geometry) << ''
    end
    lines << 'actual geometry (index left top width height):'
    lines << indent(scene.geometry) << ''

    lines << "window: #{scene.window_summary}"
    lines << "options: #{scene.option_summary}"
    lines.join("\n")
  end

  # Show a scene with explicit line ends, so trailing spaces are visible.
  def boxed(text)
    return '  (nothing captured)' if text.nil? || text.empty?

    text.split("\n", -1).reject(&:empty?).map { |l| "  |#{l}|" }.join("\n")
  end

  def indent(text)
    return '  (none)' if text.nil? || text.empty?

    text.split("\n").map { |l| "  #{l}" }.join("\n")
  end
end
