# Pane borders must be drawn on all four sides of every pane, including the
# sides that lie on the window edge, and every pane must own its own complete
# box rather than sharing a border with its neighbour.
#
# Currently tmux draws borders only *between* panes: a horizontal split has one
# vertical border column shared by both panes, and nothing around the outside.
# These tests assert the wanted behaviour, where each pane is boxed
# independently, so two side by side panes show two adjacent vertical sides
# rather than one shared one. THEY ARE EXPECTED TO FAIL until that is
# implemented; they are the failing tests that drive the work, and they must
# pass before pane-margin is started, because a margin is defined relative to a
# border that exists on every side of every pane.
#
# The windows are deliberately tiny so that a whole scene fits in a few lines
# that can be written out literally in the test.
#
# Two semantic decisions are encoded here:
#
#   Uneven space is distributed exactly as tmux distributes it today. When the
#   space left after the borders does not divide evenly, the extra cells go to
#   the later pane, which is what layout_fix_offsets1 and layout_resize_child
#   already do: a 12 column window split horizontally gives 5 and 6 today, so
#   an 11 column window under boxed borders gives content of 3 and 4.
#
#   pane-border-status renders into the pane's own top or bottom border row
#   rather than claiming an extra row, so turning it on does not change any
#   pane's size.
#
# Run directly:  ruby pane-border-edges-test.rb
# Or with rake:  rake tests

require 'minitest/autorun'
require_relative 'tmux_scene'

class PaneBorderEdgesTest < Minitest::Test
  include SceneAssertions

  # select-pane flags for the directions used by the navigation test.
  DIRECTION_FLAGS = {
    left: '-L',
    right: '-R',
    up: '-U',
    down: '-D'
  }.freeze

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = nil
  end

  def teardown
    @scene&.stop
  end

  # A window with one pane and no splits at all must still be boxed. Today the
  # pane covers every cell of the window and no border is drawn anywhere.
  #
  # With an 11x4 window the box takes the first and last column and the first
  # and last row, leaving the pane 9 columns by 2 rows.
  def test_single_pane_is_boxed
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 11, height: 4, conf: conf).start
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌─────────┐
      │.........│
      │.........│
      └─────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Resizing the window must keep the single pane boxed, with the box following
  # the window edge rather than being drawn once at the original size. The
  # window grows on both axes, so the pane grows by the same amount.
  def test_single_pane_is_boxed_after_resize
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 11, height: 4, conf: conf).start
    @scene.resize_window(width: 14, height: 6)
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────────────┐
      │............│
      │............│
      │............│
      │............│
      └────────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # And shrinking, which is the direction that has to give space back.
  def test_single_pane_is_boxed_after_shrink
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 14, height: 6, conf: conf).start
    @scene.resize_window(width: 11, height: 4)
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌─────────┐
      │.........│
      │.........│
      └─────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # A single pane with pane-border-status top: the title goes into the pane's
  # own top border, which already exists, so the pane keeps the size it has
  # with the status off. Compare with test_single_pane_is_boxed, which is the
  # same window without the status.
  #
  # The status is drawn in the pane's own border starting one cell in from the
  # corner, and the format is left aligned unless it says otherwise, so "title"
  # starts in the second cell of the border run.
  def test_single_pane_title_top
    conf = <<~CONF
      set -w -g pane-border-lines single
      set -w -g pane-border-status top
      set -w -g pane-border-format "title"
    CONF

    @scene = TmuxScene.new(width: 11, height: 4, conf: conf).start
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌─title───┐
      │.........│
      │.........│
      └─────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # The same with pane-border-status bottom: the title goes into the pane's own
  # bottom border, again without changing the pane's size.
  def test_single_pane_title_bottom
    conf = <<~CONF
      set -w -g pane-border-lines single
      set -w -g pane-border-status bottom
      set -w -g pane-border-format "title"
    CONF

    @scene = TmuxScene.new(width: 11, height: 4, conf: conf).start
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌─────────┐
      │.........│
      │.........│
      └─title───┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Two panes side by side must each get their own complete box, so the facing
  # sides are two adjacent columns rather than one shared column. Today there is
  # a single shared border column and no box.
  #
  # With a 10x4 window each pane takes a 5x4 box: one column for each vertical
  # side, one row for each horizontal side, leaving 3 columns by 2 rows of
  # content. The left box occupies columns 0 to 4 and the right box columns 5 to
  # 9, so the two content areas start at columns 1 and 6.
  def test_horizontal_split_boxes_each_pane
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 10, height: 4, conf: conf).start
    @scene.split_window('-h')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌───┐┌───┐
      │...││...│
      │...││...│
      └───┘└───┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # A 2x2 grid: four independent boxes, so the panes that meet in the middle
  # show two adjacent vertical sides and two adjacent horizontal sides rather
  # than one shared border and a crossing. Today this layout draws a single
  # vertical border, a single horizontal border and a ┼ where they cross.
  #
  # With a 12x8 window each pane takes a 6x4 box, leaving 4 columns by 2 rows of
  # content. The boxes occupy columns 0 to 5 and 6 to 11, and rows 0 to 3 and 4
  # to 7, so the content areas start at columns 1 and 7 and at rows 1 and 5.
  #
  # list-panes returns the panes in reading order for this layout: top left,
  # top right, bottom left, bottom right.
  def test_tiled_2x2_boxes_each_pane
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 12, height: 8, conf: conf).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────┐┌────┐
      │....││....│
      │....││....│
      └────┘└────┘
      ┌────┐┌────┐
      │....││....│
      │....││....│
      └────┘└────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # An odd width, so the space left after the borders does not divide evenly.
  # The extra column goes to the later pane, matching how tmux distributes
  # uneven space today: at 12 columns the current shared border layout gives 5
  # and 6, not 6 and 5.
  #
  # An 11x4 window leaves 11 - 4 = 7 content columns for two panes, so the left
  # pane gets 3 and the right pane gets 4, making the boxes 5 and 6 wide.
  def test_horizontal_split_odd_width_gives_extra_column_to_later_pane
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 11, height: 4, conf: conf).start
    @scene.split_window('-h')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌───┐┌────┐
      │...││....│
      │...││....│
      └───┘└────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # The same rule on the other axis. A 10x7 window split vertically leaves
  # 7 - 4 = 3 content rows for two panes, so the top pane gets 1 and the bottom
  # pane gets 2, making the boxes 3 and 4 rows tall.
  def test_vertical_split_odd_height_gives_extra_row_to_later_pane
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 10, height: 7, conf: conf).start
    @scene.split_window('-v')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────────┐
      │........│
      └────────┘
      ┌────────┐
      │........│
      │........│
      └────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Resizing must go through the layout tree, not just through the drawing of
  # the final pane rectangle. An implementation that shrinks panes at draw time
  # and leaves the layout believing the panes are still adjacent renders the
  # other cases correctly and fails here.
  #
  # After select-layout tiled each row owns its own column split, so resizing
  # the top left pane to the left moves only the top row's divider and leaves
  # the bottom row alone. Moving it 2 columns left turns the top row's 6 and 6
  # boxes into 4 and 8, so the content becomes 2 and 6.
  def test_resize_pane_moves_the_boxes
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 12, height: 8, conf: conf).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.fill_panes
    @scene.cmd('resize-pane', '-t0', '-L', '2')
    @scene.refill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌──┐┌──────┐
      │..││......│
      │..││......│
      └──┘└──────┘
      ┌────┐┌────┐
      │....││....│
      │....││....│
      └────┘└────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # A 2x2 in a window that divides evenly on neither axis, built with splits
  # only. The extra cell goes to the later pane on both axes, so the right
  # column is one wider than the left and the bottom row one taller than the
  # top.
  #
  # A 13x9 window has 11x7 to spend. Two columns take 2 for the separator and
  # split the remaining 9 into 4 and 5; two rows take 2 and split 5 into 2 and
  # 3.
  def test_2x2_uneven_by_splits
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 13, height: 9, conf: conf).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────┐┌─────┐
      │....││.....│
      │....││.....│
      └────┘└─────┘
      ┌────┐┌─────┐
      │....││.....│
      │....││.....│
      │....││.....│
      └────┘└─────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # The same layout reached through select-layout tiled, which recomputes every
  # cell rather than adjusting the tree the splits built, and must arrive at the
  # same answer.
  def test_2x2_uneven_tiled
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 13, height: 9, conf: conf).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────┐┌─────┐
      │....││.....│
      │....││.....│
      └────┘└─────┘
      ┌────┐┌─────┐
      │....││.....│
      │....││.....│
      │....││.....│
      └────┘└─────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Directional pane selection must keep working when every pane is boxed.
  # window_pane_find_left and friends walk from a pane's own edge into the
  # neighbouring cell, so widening the gap between two panes from one shared
  # border to two adjacent ones is exactly the kind of change that can make a
  # neighbour unreachable.
  #
  # This is a regression guard rather than a wanted-behaviour test: it passes
  # today and must keep passing. The moves at the edges wrap around to the far
  # side, which is what tmux does now.
  #
  #   0 1     -R from 0 is 1, -D from 0 is 2, and so on
  #   2 3
  def test_2x2_select_pane_directions
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 12, height: 8, conf: conf).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')

    moves = [
      # inside the grid
      { from: 0, direction: :right, expected: 1 },
      { from: 0, direction: :down,  expected: 2 },
      { from: 1, direction: :left,  expected: 0 },
      { from: 1, direction: :down,  expected: 3 },
      { from: 2, direction: :up,    expected: 0 },
      { from: 2, direction: :right, expected: 3 },
      { from: 3, direction: :left,  expected: 2 },
      { from: 3, direction: :up,    expected: 1 },
      # off the edge, wrapping to the far side
      { from: 0, direction: :left,  expected: 1 },
      { from: 0, direction: :up,    expected: 2 },
      { from: 3, direction: :right, expected: 2 },
      { from: 3, direction: :down,  expected: 1 }
    ]

    moves.each do |move|
      from = move.fetch(:from)
      direction = move.fetch(:direction)
      expected = move.fetch(:expected)

      @scene.select_pane("-t#{from}")
      @scene.select_pane(DIRECTION_FLAGS.fetch(direction))
      got = @scene.active_pane.to_i

      assert_equal expected, got,
                   "select-pane #{direction} from pane #{from} selected " \
                   "pane #{got}, expected pane #{expected}\n\n" \
                   "geometry (index left top width height):\n" \
                   "#{@scene.geometry}"
    end

    assert @scene.alive?, 'inner server died'
  end

  # display-panes draws its overlay inside each pane, so it must land inside the
  # box and never on the border. The panes are filled with dots first, so the
  # overlay is visibly drawn on top of pane content and any cell it wrongly
  # touches shows up as a missing dot.
  #
  # The window is sized so that the overlay renders in full. window-panes.c
  # draws the pane number as five by five blocks when the pane is at least 5
  # columns wide and 7 rows tall, and those blocks are spaces with a background
  # colour, so they are invisible in a plain text capture. Below that size the
  # number is drawn as an ordinary digit, which is what is asserted here: at
  # 24x12 each pane gets a 12x6 box with 10x4 of content, which is wide enough
  # for the whole size label and short enough to keep the digit form.
  #
  # The number is centred with cx = x + (sx - 1) / 2 and cy = y + sy / 2, and
  # display-panes-format defaults to a right aligned #{pane_unzoomed_width}x
  # #{pane_unzoomed_height} on the pane's first row.
  #
  # Note that display-panes draws through a second, independent border renderer:
  # it puts the active pane into panes-mode, which covers the whole window,
  # copies each pane's content into a miniature of the layout and then draws the
  # borders itself in window_panes_draw_borders. So this asserts that the other
  # renderer boxes panes too. Because the active pane becomes a full window
  # modal pane while the overlay is up, the geometry is checked before
  # display-panes is invoked.
  def test_display_panes_overlay_stays_inside_the_boxes
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 24, height: 12, conf: conf, delay: 0.5).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.fill_panes

    # Only the pane rectangles here: the scene is checked after the overlay is
    # up, and the overlay writes over the pane content.
    assert_pane_rectangles @scene, <<~LAYOUT
      ┌──────────┐┌──────────┐
      │..........││..........│
      │..........││..........│
      │..........││..........│
      │..........││..........│
      └──────────┘└──────────┘
      ┌──────────┐┌──────────┐
      │..........││..........│
      │..........││..........│
      │..........││..........│
      │..........││..........│
      └──────────┘└──────────┘
    LAYOUT

    @scene.display_panes
    @scene.capture

    # The overlay pane covers the whole window and is boxed like any other
    # pane, so the ring of cells on the window edge is its own box rather than
    # the outer sides of the four panes: the same cells, drawn as one box. The
    # overlay draws the miniature inside that box, which is where the four
    # panes' facing borders and all of their content land.
    assert_scene @scene, <<~WANT
      ┌──────────────────────┐
      │......10x4││......10x4│
      │..........││..........│
      │....0.....││....1.....│
      │..........││..........│
      │──────────┘└──────────│
      │──────────┐┌──────────│
      │......10x4││......10x4│
      │..........││..........│
      │....2.....││....3.....│
      │..........││..........│
      └──────────────────────┘
    WANT

    assert @scene.alive?, 'inner server died'
  end

  # The borders must land in exactly the same cells whether the window is drawn
  # normally or through the display-panes overlay. The overlay is drawn by a
  # second, independent renderer (window_panes_draw_borders), so the two can
  # disagree; this pins them together without either of them having to be
  # written out literally, which makes it a useful guard while the border model
  # is being changed.
  #
  # Only border glyphs are compared. The overlay's pane numbers and size labels
  # are blanked out, as is any pane content.
  def test_display_panes_draws_borders_in_the_same_place
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 24, height: 12, conf: conf, delay: 0.5).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.fill_panes

    normal = @scene.capture
    @scene.display_panes
    overlaid = @scene.capture

    # Guard against passing for the wrong reason: if the overlay has not been
    # drawn yet the two captures are identical and the border comparison below
    # succeeds without testing anything. The overlay always writes each pane's
    # size, so require that to be present.
    assert_match(/\d+x\d+/, overlaid,
                 "display-panes overlay was not drawn, so the border " \
                 "comparison would be vacuous\n\n#{overlaid}")
    refute_equal normal, overlaid,
                 "display-panes changed nothing on screen\n\n#{overlaid}"

    assert_same_borders normal, overlaid,
                        'display-panes moved the borders'

    assert @scene.alive?, 'inner server died'
  end

  # pane-border-status draws pane-border-format into the pane's own border row
  # rather than claiming a row of its own, so turning it on must not change any
  # pane's size. A literal format is used so the text is fixed: the default
  # includes the pane title, which is the hostname unless it is set.
  #
  # The status starts one cell in from the pane's own corner and the format is
  # left aligned, so the text is in the same place relative to each box however
  # many panes there are: compare with test_single_pane_title_top.
  #
  # At 20x6 each pane gets a 10x6 box with 8x4 of content. Compare with the same
  # window without pane-border-status, which has the same 8x4 content: the title
  # replaces part of the top border instead of pushing the panes down.
  def test_pane_border_status_draws_the_title_into_the_border
    conf = <<~CONF
      set -w -g pane-border-lines single
      set -w -g pane-border-status top
      set -w -g pane-border-format "title"
    CONF

    @scene = TmuxScene.new(width: 20, height: 6, conf: conf).start
    @scene.split_window('-h')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌─title──┐┌─title──┐
      │........││........│
      │........││........│
      │........││........│
      │........││........│
      └────────┘└────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # The same with pane-border-status bottom: the title goes into the pane's own
  # bottom border row, again without changing any pane's size. Centring is the
  # same as for the top row.
  def test_pane_border_status_bottom_draws_the_title_into_the_border
    conf = <<~CONF
      set -w -g pane-border-lines single
      set -w -g pane-border-status bottom
      set -w -g pane-border-format "title"
    CONF

    @scene = TmuxScene.new(width: 20, height: 6, conf: conf).start
    @scene.split_window('-h')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────────┐┌────────┐
      │........││........│
      │........││........│
      │........││........│
      │........││........│
      └─title──┘└─title──┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # The same window with pane-border-status off, to pin down that the option
  # only changes what is drawn in the border and never the pane sizes.
  def test_pane_border_status_off_has_the_same_pane_sizes
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 20, height: 6, conf: conf).start
    @scene.split_window('-h')
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────────┐┌────────┐
      │........││........│
      │........││........│
      │........││........│
      │........││........│
      └────────┘└────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # window-style and window-active-style set the default colours of pane
  # content, so they must apply to the inside of each box and never to the box
  # itself. Distinct background colours are used for the active and inactive
  # panes so that every cell can be attributed to one of them.
  #
  # The scene is captured with escape sequences and reduced to one character per
  # cell, chosen by the background colour in force when the cell was written:
  # A for the active pane (SGR 41), I for an inactive pane (SGR 44) and b for
  # the default background, which is what the borders are drawn on.
  def test_window_active_style_applies_to_pane_content_only
    conf = <<~CONF
      set -w -g pane-border-lines single
      set -g window-style bg=colour4
      set -g window-active-style bg=colour1
    CONF

    @scene = TmuxScene.new(width: 10, height: 4, conf: conf).start
    @scene.split_window('-h')
    @scene.fill_panes
    @scene.cmd('select-pane', '-t0')
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌───┐┌───┐
      │...││...│
      │...││...│
      └───┘└───┘
    LAYOUT

    assert_style_map @scene, <<~STYLES, 41 => 'A', 44 => 'I', 49 => 'b'
      bbbbbbbbbb
      bAAAbbIIIb
      bAAAbbIIIb
      bbbbbbbbbb
    STYLES

    assert @scene.alive?, 'inner server died'
  end

  # The overlay is a picture of the window, so it must draw the same glyph in
  # every border cell, on the window edge as well as inside it. The glyphs on
  # the edge are the ones the overlay renderer cannot reach: the mode's screen
  # is the zoomed pane's content, which stops one cell short of the window on
  # every side, so the ring is drawn by screen-redraw.c from the zoomed pane's
  # own box and comes out as one continuous rectangle. Every corner and T
  # junction where a hidden pane's box meets the window edge is lost: three
  # stacked panes lose the six elbows on each side and get plain verticals.
  #
  # This is the same comparison as
  # test_display_panes_draws_borders_in_the_same_place, without the window edge
  # being reduced to presence only.
  def test_display_panes_draws_the_same_border_glyphs_on_the_window_edge
    conf = <<~CONF
      set -w -g pane-border-lines single
    CONF

    @scene = TmuxScene.new(width: 24, height: 12, conf: conf, delay: 0.5).start
    @scene.split_window('-v')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'even-vertical')
    @scene.blank_panes

    normal = @scene.capture
    @scene.display_panes
    overlaid = @scene.capture

    assert_match(/\d+x\d+/, overlaid,
                 "display-panes overlay was not drawn, so the border " \
                 "comparison would be vacuous\n\n#{overlaid}")

    assert_same_borders normal, overlaid,
                        'display-panes changed the border glyphs',
                        edge_presence: false

    assert @scene.alive?, 'inner server died'
  end

  # The overlay is a miniature of the window, so a border in it must be styled
  # like the same border outside it: the overlay has its own renderer and used
  # to paint every border with one flat style of its own, which showed up as
  # borders that changed colour, and lost their background, while the numbers
  # were up.
  #
  # Backgrounds are used because they can be read back per cell: the inactive
  # panes' borders are SGR 44, the active pane's border is SGR 41 and pane
  # content is on the default background.
  def test_display_panes_overlay_borders_keep_the_pane_border_styles
    conf = <<~CONF
      set -w -g pane-border-lines single
      set -g pane-border-style bg=colour4
      set -g pane-active-border-style bg=colour1
    CONF

    @scene = TmuxScene.new(width: 24, height: 12, conf: conf, delay: 0.5).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.cmd('select-pane', '-t0')
    @scene.fill_panes

    @scene.display_panes

    # The ring on the window edge is the box of the pane the overlay is a mode
    # of, which is the active pane, so it is the active border style. Every
    # border inside it is drawn by the overlay, and each one carries the style
    # of the pane it belongs to: the active pane's box is A, the other three
    # are I.
    assert_style_map @scene, <<~STYLES, 41 => 'A', 44 => 'I', 49 => 'b'
      AAAAAAAAAAAAAAAAAAAAAAAA
      AbbbbbbbbbbAIbbbbbbbbbbA
      AbbbbbbbbbbAIbbbbbbbbbbA
      AbbbbbbbbbbAIbbbbbbbbbbA
      AbbbbbbbbbbAIbbbbbbbbbbA
      AAAAAAAAAAAAIIIIIIIIIIIA
      AIIIIIIIIIIIIIIIIIIIIIIA
      AbbbbbbbbbbIIbbbbbbbbbbA
      AbbbbbbbbbbIIbbbbbbbbbbA
      AbbbbbbbbbbIIbbbbbbbbbbA
      AbbbbbbbbbbIIbbbbbbbbbbA
      AAAAAAAAAAAAAAAAAAAAAAAA
    STYLES

    assert @scene.alive?, 'inner server died'
  end
end
