require 'fileutils'
require 'shellwords'

ROOT       = File.expand_path(__dir__)
PREFIX     = File.join(ROOT, 'build-output')
TMUX_BIN   = File.join(PREFIX, 'bin', 'tmux')
REGRESS    = File.join(ROOT, 'regress')
LOGDIR     = File.join(REGRESS, 'logs')
CONFIGURE_STAMP = File.join(ROOT, '.rake-configure-stamp')
MAKE       = ENV['MAKE'] || (system('command -v gmake >/dev/null 2>&1') ? 'gmake' : 'make')
JOBS       = ENV['JOBS'] || `getconf _NPROCESSORS_ONLN`.strip
CONFIGURE_ARGS = (ENV['CONFIGURE_ARGS'] || '--enable-utf8proc').shellsplit
CFLAGS     = ENV['CFLAGS'] || '-O2 -g'
# Concurrent topics. Above ~8 the capture-and-compare tests get flaky on this
# box (client has not redrawn when the scene is captured).
TEST_JOBS  = [(ENV['TEST_JOBS'] || [JOBS.to_i, 8].min).to_i, 1].max
def sh!(*cmd, chdir: ROOT)
  puts "==> #{cmd.shelljoin}"
  ok = system(*cmd, chdir: chdir)
  raise "command failed (#{$?.exitstatus}): #{cmd.shelljoin}" unless ok
end

def clean
  if File.exist?(File.join(ROOT, 'Makefile'))
    system(MAKE, 'distclean', chdir: ROOT, out: File::NULL, err: File::NULL)
  end
  FileUtils.rm_rf([PREFIX, LOGDIR])
  FileUtils.rm_f(Dir[File.join(ROOT, '*.o')] +
                 Dir[File.join(ROOT, 'compat', '*.o')] +
                 [File.join(ROOT, 'tmux'),
                  File.join(ROOT, 'tmux.1.mdoc'),
                  File.join(ROOT, 'tmux.1.man'),
                  File.join(ROOT, 'Makefile'),
                  File.join(ROOT, 'config.status'),
                  File.join(ROOT, 'config.log'),
                  File.join(ROOT, 'config.h'),
                  CONFIGURE_STAMP])
  puts 'cleaned'
end

# configure is regenerated when either autotools input changes; Makefile.am
# matters too, or a newly added source file is silently never compiled.
def autotools_inputs_mtime
  %w[configure.ac Makefile.am].map { |f| File.mtime(File.join(ROOT, f)) }.max
end

# Re-run configure when its inputs change. mtime alone misses CFLAGS= and
# CONFIGURE_ARGS= changes, which would otherwise reuse a Makefile built with
# different flags than the ones asked for.
def configure_stale?(configure, makefile)
  return true unless File.exist?(makefile) && File.exist?(CONFIGURE_STAMP)
  return true if File.mtime(configure) > File.mtime(makefile)

  File.read(CONFIGURE_STAMP) != configure_signature
end

def configure_signature
  [PREFIX, CFLAGS, *CONFIGURE_ARGS].join("\n")
end

def build
  configure = File.join(ROOT, 'configure')
  if !File.exist?(configure) || autotools_inputs_mtime > File.mtime(configure)
    sh! 'sh', 'autogen.sh'
    # autoreconf leaves configure alone when nothing changed, which would keep
    # it older than its inputs and re-run autogen on every build.
    FileUtils.touch(configure)
  end

  makefile = File.join(ROOT, 'Makefile')
  if configure_stale?(configure, makefile)
    sh! configure, "--prefix=#{PREFIX}", "CFLAGS=#{CFLAGS}", *CONFIGURE_ARGS
    File.write(CONFIGURE_STAMP, configure_signature)
  end

  sh! MAKE, "-j#{JOBS}"
  sh! MAKE, 'install'

  raise "missing installed binary: #{TMUX_BIN}" unless File.executable?(TMUX_BIN)
  puts "installed: #{TMUX_BIN}"
end

# Tests to run, grouped into topics. Tests inside a topic run serially and
# topics run in parallel, at most TEST_JOBS at a time. A topic with
# parallel: true gives each of its tests a lane instead. OPT_IN_TOPICS are
# skipped unless named with topics=.
TEST_LIST = [
  {
    # cmd-queue.c: queue ordering, nested/deferred sub-queues, blocking items,
    # hook insertion and cmdq error reporting. control-client-sanity.sh also
    # exercises command batching but is owned by :layout.
    topic: :cmd_queue,
    paths: %w[
      conf-syntax.sh
      if-shell-nested.sh if-shell-TERM.sh if-shell-error.sh
      run-shell-output.sh cfg-client-lost.sh lifecycle-deferred.sh
      wait-for-E.sh set-hook-E.sh set-hook-R.sh
      hooks.sh hooks-after.sh hooks-notify.sh hooks-lifecycle.sh
      control-notify-guard.sh control-subscriptions.sh targets.sh
    ]
  },
  {
    # layout.c, layout-custom.c (layout_dump via #{window_layout}) and
    # layout-set.c (select-layout). Tests already owned by a screen_redraw_*
    # topic are not repeated here.
    topic: :layout,
    paths: %w[
      pane-ops.sh window-ops.sh control-client-sanity.sh
    ]
  },
  {
    # screen-redraw.c border drawing: pane borders, border status/arrows,
    # indicators, window styles.
    topic: :screen_redraw_border,
    paths: %w[
      screen-redraw-tiled.sh screen-redraw-indicators.sh
      screen-redraw-window-style.sh border-arrows.sh
    ]
  },
  {
    # screen-redraw.c floating/modal pane drawing and geometry.
    topic: :screen_redraw_floating,
    paths: %w[
      floating-pane-geometry.sh
    ]
  },
  {
    # screen-redraw.c scene composition: OUTSIDE spans, fill-character, scene
    # cache invalidation, bidi isolate, popup overlays, scrollbars, status.
    topic: :screen_redraw_scene,
    paths: %w[
      screen-redraw-bidi.sh screen-redraw-cache.sh
      screen-redraw-fill-character.sh screen-redraw-outside.sh
      screen-redraw-popups.sh screen-redraw-scrollbars.sh
      screen-redraw-status.sh
    ]
  },
  {
    # screen-redraw.c menu overlay drawing (redraw_mark_menu).
    topic: :screen_redraw_menu,
    paths: %w[
      menu-mouse.sh
    ]
  },
  {
    # window-panes.c (panes-mode), only reachable via display-panes.
    topic: :display_panes,
    paths: %w[
      display-panes.sh mode-kill.sh
    ]
  },
  {
    # spawn.c: new-session, new-window, new-pane.
    topic: :new,
    paths: %w[
      new-pane-mouse.sh new-session-base-index.sh new-session-command.sh
      new-session-environment.sh new-session-no-client.sh new-session-size.sh
      new-window-command.sh
    ]
  },
  {
    # format.c / format-draw.c.
    topic: :format,
    paths: %w[
      format-animation.sh format-fuzzy.sh format-modifiers.sh format-mouse.sh
      format-render-contexts.sh format-strings.sh format-variables.sh
    ]
  },
  {
    # window mode UIs: mode-tree.c, window-copy.c, window-buffer/client/tree.c,
    # window-customize.c.
    topic: :modes,
    paths: %w[
      buffers.sh choose-buffer.sh choose-client.sh choose-tree.sh
      mode-mutation.sh copy-mode-redraw.sh
      copy-mode-scroll-exit.sh copy-mode-selection-scroll.sh
      copy-mode-test-emacs.sh copy-mode-test-vi.sh
    ]
  },
  {
    # terminal level: tty.c, tty-term.c, tty-draw.c, tty-keys.c, utf8.c.
    topic: :tty,
    paths: %w[
      am-terminal.sh capture-pane-hyperlink.sh capture-pane-sgr0.sh
      cursor-test1.sh cursor-test2.sh cursor-test3.sh cursor-test4.sh
      decrqm-sync.sh sync-output-atomic.sh
      tty-draw-line.sh tty-keys.sh utf8-test.sh
    ]
  },
  {
    # options.c, options-table.c, style.c.
    topic: :options,
    paths: %w[
      options-array.sh options-scope.sh options-values.sh
      show-options-output.sh style-trim.sh theme-report.sh
      tab-cell-background.sh
    ]
  },
  {
    # server.c, server-client.c, session.c, environ.c, alerts.c.
    topic: :session,
    paths: %w[
      control-client-size.sh control-notify-events.sh environ.sh
      environ-update.sh has-session-return.sh kill-session-process-exit.sh
      server-socket-error.sh session-group-resize.sh session-ops.sh
    ]
  },
  {
    # Scratch topic for whatever is being worked on. Run with `rake focus`.
    # parallel: N -> N tests per lane instead of the whole topic in one lane.
    parallel: 2,
    # Currently: tests that kill mutations of the geometry arithmetic in
    # layout.c (g.sx/g.sy/g.xoff/g.yoff +/- 1, +/- 2). Duplicates of other
    # topics on purpose.
    topic: :focus,
    paths: %w[
      border-arrows.sh control-client-sanity.sh display-panes.sh
      floating-pane-geometry.sh pane-ops.sh screen-redraw-bidi.sh
      screen-redraw-cache.sh screen-redraw-floating.sh screen-redraw-indicators.sh
      screen-redraw-outside.sh screen-redraw-popups.sh screen-redraw-scrollbars.sh
      screen-redraw-status.sh screen-redraw-tiled.sh screen-redraw-window-style.sh
      screen-redraw-fill-character.sh targets-panes.sh
    ]
  },
  {
    # Long running tests, split out so they do not hold up a topical bucket.
    topic: :slow,
    paths: %w[
      alerts.sh osc-11colours.sh customize-mode.sh set-hook-B.sh
    ]
  },
  {
    # Not run by default: broken upstream, or a fixed -L socket that collides
    # with parallel topics. Run with topics=ignore.
    topic: :ignore,
    paths: %w[
      command-order.sh
      prompt-keys.sh
      control-client-exit.sh control-client-exit-stalled.sh
      control-client-wait-exit.sh respawn-pane-control-lag.sh
      check-names.sh screen-redraw-menus.sh input-replies.sh
      screen-redraw-floating.sh modal-pane.sh
      input-cursor.sh input-edit.sh input-keys.sh input-malformed.sh
      input-modes.sh input-osc.sh input-raw-controls.sh input-raw-cursor.sh
      input-raw-edit.sh input-raw-history.sh input-raw-reflow.sh
      input-raw-scroll.sh input-raw-sgr.sh input-raw-unicode.sh
      input-raw-wrap.sh input-reflow-stress.sh
      input-requests.sh input-scroll.sh input-sgr.sh input-unicode.sh
      cmd-template-replace.sh combine-test.sh command-alias.sh
      pipe-pane.sh prompt-mechanics.sh targets-panes.sh
    ]
  },
].freeze

# topics=a,b on the rake command line (or TOPICS=a,b) selects topics by name.
def selected_topics
  raw = ENV['topics'] || ENV['TOPICS']
  return nil if raw.nil? || raw.strip.empty?
  raw.split(',').map { |t| t.strip.to_sym }.reject { |t| t.to_s.empty? }
end

# Topics skipped unless named explicitly with topics=.
OPT_IN_TOPICS = %i[ignore slow focus].freeze

# Resolve TEST_LIST into lanes of absolute paths.
def test_list(want_topics)
  wanted = Array(want_topics).map(&:to_sym)
  lanes = TEST_LIST.flat_map do |t|
    paths = t[:paths].map { |n| File.join(REGRESS, n) }
    next [{ topic: t[:topic], paths: paths }] unless t[:parallel]

    # parallel: true -> one test per lane, parallel: N -> N tests per lane.
    batch = t[:parallel] == true ? 1 : Integer(t[:parallel])
    paths.each_slice(batch).map { |slice| { topic: t[:topic], paths: slice } }
  end

  lanes.reject do |lane|
    lane[:paths].empty? ||
      (OPT_IN_TOPICS.include?(lane[:topic].to_sym) &&
       !wanted.include?(lane[:topic].to_sym))
  end
end

# Aborted runs and tests that fail before their cleanup leave servers behind;
# they hold ptys and eventually break fork with "Device not configured".
# Scoped to -Ltest* sockets of the built binary, so a personal tmux (system
# tmux, or this binary on another socket) is never touched.
def stale_server_pids
  stale_servers.map(&:first)
end

def stale_servers
  mine = Process.pid
  `ps -axo pid=,command=`.lines.filter_map do |line|
    pid, cmd = line.strip.split(' ', 2)
    next if cmd.nil? || pid.to_i == mine
    # tmux from this checkout (any path spelling) on a -Ltest* socket only.
    next unless cmd.include?('build-output/bin/tmux')
    next unless cmd =~ /\s-Ltest[A-Za-z]*\d*(?:-\d+)?(?:\s|\z)/

    [pid.to_i, cmd]
  end
end

def kill_stale_servers
  procs = stale_servers
  return if procs.empty?

  puts "killing #{procs.size} stale test server(s)"
  targets = procs.map(&:first)
  targets.each { |pid| Process.kill('TERM', pid) rescue nil }
  sleep 1

  # Re-scan rather than trusting the old pids: between TERM and KILL a pid can
  # be recycled by an unrelated process.
  survivors = stale_server_pids & targets
  survivors.each { |pid| Process.kill('KILL', pid) rescue nil }
end

def validate_topics!(want_topics)
  return unless want_topics

  known = TEST_LIST.map { |t| t[:topic].to_sym }
  unknown = want_topics - known
  return if unknown.empty?

  raise "unknown topic(s): #{unknown.join(', ')} (known: #{known.join(', ')})"
end

def select_topics(topics, want_topics)
  return topics unless want_topics

  topics.select { |t| want_topics.include?(t[:topic].to_sym) }
end

# TESTS="a.sh b.sh" narrows the selected topics to those test names.
def filter_tests(topics)
  only = ENV['TESTS']
  return topics unless only

  want = only.shellsplit.map { |t| File.basename(t) }
  filtered = topics.map do |t|
    paths = t[:paths].select { |p| want.include?(File.basename(p)) }
    { topic: t[:topic], paths: paths }
  end

  filtered.reject { |t| t[:paths].empty? }
end

def check_not_empty!(tests, want_topics)
  return unless tests.empty?

  if want_topics == [:focus]
    raise 'the :focus topic is empty; add test names to it in TEST_LIST'
  end
  raise 'no tests found'
end

# Everything on disk or in TEST_LIST that this run will not execute.
def ignored_tests(topics)
  on_disk = Dir[File.join(REGRESS, '*.sh')].map { |p| File.basename(p) }
  listed = TEST_LIST.flat_map { |t| t[:paths] }
  selected = topics.flat_map { |t| t[:paths].map { |p| File.basename(p) } }

  ((on_disk - listed) + (listed - selected)).uniq.sort
end

def reset_logs
  FileUtils.mkdir_p(LOGDIR)
  Dir[File.join(LOGDIR, '*.log')].each { |f| File.delete(f) if File.exist?(f) }
end

# A test may appear in more than one selected topic (:focus duplicates on
# purpose); qualify those logs with the topic so the runs do not race.
def log_path(topic, name, dup_names)
  stem = name.sub(/\.sh\z/, '')
  stem = "#{topic}-#{stem}" if dup_names.include?(name)
  File.join(LOGDIR, "#{stem}.log")
end

# Run one test script, returning [ok, seconds]. Output goes to log.
def run_test(name, log)
  start = Time.now
  ok = File.open(log, 'w') do |io|
    pid = Process.spawn(
      'env', '-i',
      'LC_CTYPE=C.UTF-8',
      'MallocNanoZone=0',
      "TEST_TMUX=#{TMUX_BIN}",
      'sh', '-x', name,
      chdir: REGRESS, out: io, err: [:child, :out]
    )
    _, status = Process.waitpid2(pid)
    status.success?
  end
  [ok, (Time.now - start).round]
end

# Run every lane, at most TEST_JOBS at a time. Returns the failed test names.
def run_lanes(topics)
  tests = topics.flat_map { |t| t[:paths] }
  dup_names = tests.map { |p| File.basename(p) }.tally.select { |_, n| n > 1 }.keys
  concurrency = [TEST_JOBS, topics.size].min
  slots = Thread::Queue.new
  concurrency.times { slots << true }

  puts "running #{tests.size} tests in #{topics.size} lane(s), " \
       "#{concurrency} at a time: #{topics.map { |t| t[:topic] }.uniq.join(', ')}"

  failures = []
  mutex = Mutex.new

  workers = topics.map do |topic|
    Thread.new do
      slots.pop
      begin
        topic[:paths].each do |path|
          name = File.basename(path)
          log = log_path(topic[:topic], name, dup_names)
          ok, secs = run_test(name, log)

          mutex.synchronize do
            File.delete(log) if ok && File.exist?(log)
            puts format('%-40s %s (%ds)', name, ok ? 'PASS' : 'FAIL', secs)
            next if ok

            puts " log: #{log}"
            failures << name
          end
        end
      rescue StandardError => e
        # A crashed lane must not discard the other lanes' results.
        mutex.synchronize do
          puts format('%-40s LANE ERROR (%s)', topic[:topic], e.class)
          puts " #{e.message}"
          failures << "#{topic[:topic]} lane: #{e.class}: #{e.message}"
        end
      ensure
        slots << true
      end
    end
  end

  workers.each { |w| w.join rescue nil }
  failures
end

def report(ignored, failures)
  unless ignored.empty?
    puts
    puts "ignored #{ignored.size} test(s):"
    ignored.each { |name| puts " #{name}" }
  end

  if failures.empty?
    # Dir.rmdir raises ENOTEMPTY when a log survived; that means a test failed
    # without being recorded, so never report green on top of it.
    leftover = Dir[File.join(LOGDIR, '*.log')].map { |f| File.basename(f) }
    unless leftover.empty?
      raise "no failures recorded but logs remain: #{leftover.join(', ')}"
    end

    Dir.rmdir(LOGDIR) rescue nil
    puts 'all tests passed'
    return
  end

  puts
  puts 'failures:'
  failures.each { |name| puts " #{name}" }
  raise "#{failures.size} test(s) failed"
end

def test
  raise 'not built; run build first' unless File.executable?(TMUX_BIN)

  kill_stale_servers

  want_topics = selected_topics
  validate_topics!(want_topics)

  topics = filter_tests(select_topics(test_list(want_topics), want_topics))
  tests = topics.flat_map { |t| t[:paths] }
  check_not_empty!(tests, want_topics)

  ignored = ignored_tests(topics)
  reset_logs
  report(ignored, run_lanes(topics))
end

desc 'remove build artifacts, build-output/ and test logs'
task(:clean) { clean }

desc 'configure, compile and install into build-output/'
task(:build) { build }

desc 'clean then build from scratch'
task rebuild: %i[clean build]

desc 'run regress suite against build-output/bin/tmux (topics=a,b to select)'
task(test: :build) { test }

desc 'run only the :focus topic'
task(focus: :build) do
  ENV['topics'] = 'focus'
  test
end

task :default do
  build
  test
end
