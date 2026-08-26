# pane-border-status costs no pane a row.
#
# Upstream a pane had no border of its own at the window edge, so a pane whose
# status line was drawn at its top or bottom had to give up a row of its own
# grid for it. That is what layout_add_horizontal_border decided, and five
# places in layout.c reserved the row it asked for:
#
#     layout_fix_panes         yoff++ and sy--
#     layout_resize_check      minimum = PANE_MINIMUM + 1
#     layout_split_check_space minimum = PANE_MINIMUM * 2 + 2
#     layout_spread_cell       size = parent->g.sy - 1, and each + 1 per child
#
# With boxed borders every pane has a border row on all four sides whatever
# the layout is, so the status line is drawn into a row that exists anyway and
# nothing needs reserving. layout_add_horizontal_border returns 0 for that
# reason, which makes all five reservations dead code, and this suite is the
# fence that keeps them dead: nothing else pins it, and every one of them is a
# `+ 1` of the kind the boxed conversion has already had to chase down four
# times (layout-custom.c, layout_insert_tile, layout_get_tiled_cell,
# window minimum size).
#
# The failures this catches are not subtle. With the reservation restored
# (probed by making layout_add_horizontal_border return status != off), three
# panes spread down a 20-wide window come out as:
#
#     height  status off              status top
#      9      1+1  4+1  7+1          2+1  6+1  10+1   <- last pane outside
#     10      1+1  4+1  7+2          2+1  6+1  10+1
#     12      1+2  5+2  9+2          2+1  6+2  11+2
#
# i.e. every pane is pushed down a row and the layout no longer fits the
# window at all, and a picture of two panes loses a row per pane:
#
#     ┌─ 0 ──────┐        (blank)
#     │..........│        ┌─ 0 ──────┐
#     │..........│        │..........│
#     └──────────┘        └──────────┘
#     ┌─ 1 ──────┐        (blank)
#     ...                 ...
#
# Run directly:  ruby layout-border-status-test.rb
# Or with rake:  rake tests TEST=layout-border-status

require 'minitest/autorun'
require_relative 'tmux_scene'

class LayoutBorderStatusTest < Minitest::Test
  include SceneAssertions

  STATUSES = %w[off top bottom].freeze

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scenes = []
  end

  def teardown
    @scenes.each(&:stop)
  end

  # pane-border-status is a window option, and the format is set so that a
  # title is short enough to see the border either side of it.
  def conf_for(status)
    <<~CONF
      set -w -g pane-border-lines single
      set -g pane-border-status #{status}
      set -g pane-border-format " #P "
    CONF
  end

  def scene(status, width:, height:)
    scene = TmuxScene.new(width: width, height: height,
                          conf: conf_for(status)).start
    @scenes << scene
    scene
  end

  # panes panes split in direction in a window of the given size. The window
  # starts big enough for the splits to be taken at all and is resized to the
  # size under test afterwards, because a split of an already tiny window is
  # refused before the layout arithmetic is reached.
  def spread_scene(status, panes, direction, width:, height:)
    s = scene(status, width: width, height: [height, 20].max)
    (panes - 1).times { s.split_window(direction) }
    s.resize_window(width: width, height: height)
    s.cmd('select-layout',
          direction == '-v' ? 'even-vertical' : 'even-horizontal')
    s
  end

  # The picture: two panes down a 12x8 window, with a title in the top border
  # of each. Every pane keeps both of its content rows whether the status is
  # drawn or not, so the only difference between the three captures is which
  # border row carries the title.
  def test_status_off_draws_two_full_panes
    s = scene('off', width: 12, height: 8)
    s.split_window('-v')
    s.fill_panes
    s.capture

    assert_scene s, <<~WANT
      ┌──────────┐
      │..........│
      │..........│
      └──────────┘
      ┌──────────┐
      │..........│
      │..........│
      └──────────┘
    WANT
  end

  def test_status_top_draws_the_title_into_the_top_border_of_each_pane
    s = scene('top', width: 12, height: 8)
    s.split_window('-v')
    s.fill_panes
    s.capture

    assert_scene s, <<~WANT
      ┌─ 0 ──────┐
      │..........│
      │..........│
      └──────────┘
      ┌─ 1 ──────┐
      │..........│
      │..........│
      └──────────┘
    WANT
  end

  def test_status_bottom_draws_the_title_into_the_bottom_border_of_each_pane
    s = scene('bottom', width: 12, height: 8)
    s.split_window('-v')
    s.fill_panes
    s.capture

    assert_scene s, <<~WANT
      ┌──────────┐
      │..........│
      │..........│
      └─ 0 ──────┘
      ┌──────────┐
      │..........│
      │..........│
      └─ 1 ──────┘
    WANT
  end

  # layout_spread_cell divides the parent cell between its children, and used
  # to take a row off it first. At height 9 three panes fit exactly (9 =
  # 3 + 2 * LAYOUT_SEPARATOR + 2 * LAYOUT_BORDER), so a row taken off here has
  # nowhere to come from and the last pane ends up outside the window.
  def test_a_spread_at_the_minimum_height_ignores_pane_border_status
    want = <<~GEOMETRY
      0 1 1 18 1
      1 1 4 18 1
      2 1 7 18 1
    GEOMETRY

    STATUSES.each do |status|
      s = spread_scene(status, 3, '-v', width: 20, height: 9)

      assert_geometry s, want,
                      "spread moved with pane-border-status #{status}"
      assert_panes_inside_window s
    end
  end

  # One row per pane above the minimum, which is where the division has a
  # remainder to hand out: a row taken off the parent first changes every
  # pane's height as well as its position, so this catches a reservation that
  # the exact fit above would only show as an overflow.
  def test_a_spread_with_room_to_spare_ignores_pane_border_status
    want = <<~GEOMETRY
      0 1 1 18 2
      1 1 5 18 2
      2 1 9 18 2
    GEOMETRY

    STATUSES.each do |status|
      s = spread_scene(status, 3, '-v', width: 20, height: 12)

      assert_geometry s, want,
                      "spread moved with pane-border-status #{status}"
      assert_panes_inside_window s
    end
  end

  # The other axis, where the status line has never cost anything: a left-right
  # spread is here so that a fix which subtracts the row from the wrong parent,
  # or from both, fails too.
  def test_a_spread_across_ignores_pane_border_status
    want = <<~GEOMETRY
      0 1 1 4 10
      1 7 1 5 10
      2 14 1 5 10
    GEOMETRY

    STATUSES.each do |status|
      s = spread_scene(status, 3, '-h', width: 20, height: 12)

      assert_geometry s, want,
                      "spread moved with pane-border-status #{status}"
      assert_panes_inside_window s
    end
  end

  # layout_resize_check said a pane drawing a status line could not be shrunk
  # to PANE_MINIMUM, only to PANE_MINIMUM + 1, so a resize stopped a cell early
  # and the cell it refused to give up stayed with the pane being shrunk. The
  # resizes are run one at a time and to exhaustion: tmux clamps rather than
  # erroring, and the last one that has an effect is the boundary under test.
  def test_shrinking_a_pane_to_the_minimum_ignores_pane_border_status
    want = <<~GEOMETRY
      0 1 1 18 5
      1 1 8 18 1
    GEOMETRY

    STATUSES.each do |status|
      s = scene(status, width: 20, height: 10)
      s.split_window('-v')
      6.times { s.cmd('resize-pane', '-t0', '-D', '1') }

      assert_geometry s, want,
                      "resize stopped short with pane-border-status #{status}"
      assert_panes_inside_window s
    end
  end

  # layout_split_check_space is the same arithmetic for a split: two panes down
  # need 6 rows (2 + LAYOUT_SEPARATOR + 2 * LAYOUT_BORDER) and a reservation on
  # top of that would refuse the split outright.
  def test_a_split_at_the_minimum_height_is_taken_whatever_the_status
    want = <<~GEOMETRY
      0 1 1 18 1
      1 1 4 18 1
    GEOMETRY

    STATUSES.each do |status|
      s = scene(status, width: 20, height: 6)
      s.split_window('-v')

      assert_equal 2, s.pane_indexes.size,
                   "split refused with pane-border-status #{status}"
      assert_geometry s, want
      assert_panes_inside_window s
    end
  end
end
