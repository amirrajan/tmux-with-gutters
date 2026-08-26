# What the display-panes overlay leaves out of the borders it redraws.
#
# TWO OF FOUR FAIL ON PURPOSE. They exist so that checking the overlay against
# the real borders is a test run and not an eyeball pass over a live server.
# The reverse attribute is fixed and pinned; titles and arrows are still open.
#
# The overlay is drawn by two renderers at once. Zooming the pane it is a mode
# of leaves a ring of cells on the window edge that the overlay's own screen
# cannot reach, so screen-redraw.c draws that ring from the layout the overlay
# hides (redraw_mark_overlay_borders) and window_panes_draw_borders draws
# everything inside it. Glyphs, styles and pane-border-lines already agree
# across that seam, pinned by pane-border-edges-test.rb. Three things do not,
# and each of them is only drawn by the ring:
#
#   1. the marked pane's reverse attribute (redraw_draw_border_span)
#   2. pane-border-status titles
#   3. pane-border-indicators arrows
#
# The reverse attribute was the first of those, and is fixed: for a two pane
# 24x8 window with pane 0 marked it was on pane 0's whole box normally and on
# three sides of it with the numbers up, the fourth being interior:
#
#     normal                     overlay, before the fix
#     RRRRRRRRRRRRRRRRRRRRRRRR   RRRRRRRRRRRRRRRRRRRRRRRR
#     R......................R   R......................R
#     R......................R   R......................R
#     RRRRRRRRRRRRRRRRRRRRRRRR   R......................R  <- not reversed
#
# window_panes_get_border_style now applies the same exclusive or as
# redraw_draw_border_span. One thing it does not fix: the overlay's screen is
# only redrawn on a resize or a key, so marking a pane from another client while
# the numbers are already up leaves the interior stale until the next redraw.
# Both tests below mark before the overlay goes up, which is the only way to get
# there with one client anyway, since the overlay takes every key.
#
# Titles and arrows are absent from the overlay everywhere, edge included: the
# ring pass marks border cells but not status cells, and the overlay never drew
# either. That is at least uniform, so the decision is open - the overlay could
# draw them, or it could be documented as deliberately plain - but it cannot
# stay accidental. Whichever way it goes, delete or invert the two tests below
# and say so in the commit message.
#
# The reverse attribute has no such decision to make: half a box in reverse is
# wrong under any reading.
#
# Run directly:  ruby display-panes-parity-test.rb
# Or with rake:  rake tests TEST=display-panes-parity

require 'minitest/autorun'
require_relative 'tmux_scene'

class DisplayPanesParityTest < Minitest::Test
  include SceneAssertions

  # Arrow glyphs redraw_mark_border_arrows draws, one per side.
  ARROWS = %w[↑ ↓ ← →].freeze

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = nil
  end

  def teardown
    @scene&.stop
  end

  # Two panes down a 24x8 window, so each box is 24x4 and the seam between the
  # two renderers runs along the inside of each box. The panes are left blank:
  # only the borders are under test.
  def two_pane_scene(conf)
    @scene = TmuxScene.new(width: 24, height: 8, conf: conf, delay: 0.5).start
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.blank_panes
    @scene
  end

  # The overlay writes each pane's size, so this is what says it is actually up.
  # Without it every comparison below would pass by comparing a capture with
  # itself.
  def assert_overlay_drawn(capture)
    assert_match(/\d+x\d+/, capture,
                 "display-panes overlay was not drawn, so the comparison " \
                 "would be vacuous\n\n#{capture}")
  end

  # select-pane -m puts the marked pane's border in reverse. The overlay has to
  # agree with the real borders cell for cell, or the marked pane changes shape
  # while the numbers are up.
  def test_the_overlay_draws_the_marked_pane_border_in_reverse
    two_pane_scene("set -w -g pane-border-lines single\n")
    @scene.cmd('select-pane', '-m', '-t0')

    @scene.capture
    normal = @scene.capture_escapes

    # All four sides of the marked pane's box, absolutely, not just "some cells
    # are reversed": tiled boxes share no border cell, so the reversed ring is
    # the marked pane and nothing else. Upstream could only mark the sides a
    # pane shared with a neighbour, one or two of them, and a lone pane in a
    # window could not be marked at all. Pinning the picture here means a change
    # that shrinks the mark back to that in both renderers fails, which the
    # overlay-against-normal comparison below would not catch.
    assert_equal <<~REVERSE, reverse_map(normal),
      RRRRRRRRRRRRRRRRRRRRRRRR
      R......................R
      R......................R
      RRRRRRRRRRRRRRRRRRRRRRRR
      ........................
      ........................
      ........................
      ........................
    REVERSE
                 "the marked pane's box is not reversed on all four sides"

    @scene.display_panes
    assert_overlay_drawn @scene.capture
    overlaid = @scene.capture_escapes

    assert_same_reverse normal, overlaid,
                        'display-panes changed which cells are in reverse'
  end

  # The same with the marked pane not the active one, in a tiled 2x2. Border
  # cells are owned per box and the active pane wins any cell two boxes share,
  # so this is where a fix that reverses by owner rather than by mark, or that
  # loses the mark to the active pane's style, shows up.
  def test_the_overlay_reverses_a_marked_pane_that_is_not_active
    @scene = TmuxScene.new(width: 24, height: 12,
                           conf: "set -w -g pane-border-lines single\n",
                           delay: 0.5).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.cmd('select-pane', '-t3')
    @scene.cmd('select-pane', '-m', '-t1')
    @scene.blank_panes

    @scene.capture
    normal = @scene.capture_escapes

    refute_equal @scene.cmd('display', '-p', '\#{pane_index}'), '1',
                 'the marked pane is the active one, so this is the other test'
    assert_includes reverse_map(normal), 'R',
                    "the marked pane's border is not in reverse at all"

    @scene.display_panes
    assert_overlay_drawn @scene.capture

    assert_same_reverse normal, @scene.capture_escapes,
                        'display-panes changed which cells are in reverse'
  end

  # pane-border-status draws pane-border-format into the pane's own border row.
  # The overlay redraws those rows and drops the text.
  def test_the_overlay_draws_pane_border_status_titles
    two_pane_scene(<<~CONF)
      set -w -g pane-border-lines single
      set -g pane-border-status top
      set -g pane-border-format " #P "
    CONF

    normal = @scene.capture

    assert_includes normal, '─ 0 ',
                    "pane-border-status is not drawn at all\n\n#{normal}"

    @scene.display_panes
    overlaid = @scene.capture
    assert_overlay_drawn overlaid

    # The whole border row is compared, not the text on its own: the overlay
    # writes each pane's number into the pane, so a substring test for " 0 "
    # passes on the number rather than on the title. Rows 0 and 4 are the top
    # border of each box in a 24x8 window with one split.
    normal_rows = normal.split("\n")
    overlaid_rows = overlaid.split("\n")

    [0, 4].each do |row|
      assert_equal normal_rows[row], overlaid_rows[row],
                   "display-panes redrew border row #{row} without its " \
                   "pane-border-status title\n\nnormal:\n#{normal}\n" \
                   "overlay:\n#{overlaid}"
    end
  end

  # A title row on the window edge is marked and drawn by screen-redraw.c and
  # one inside it by the overlay, so a window with a box in each place pins both
  # halves against each other. The format is longer than a box is wide, which is
  # the case the overlay has to truncate: it is a miniature, so the room between
  # two corners can be less than the format asks for, and the two renderers have
  # to cut it at the same cell.
  def test_the_overlay_truncates_titles_where_the_real_borders_do
    @scene = TmuxScene.new(width: 40, height: 12, delay: 0.5, conf: <<~CONF).start
      set -w -g pane-border-lines single
      set -g pane-border-status top
      set -g pane-border-format " pane #P of a very long title "
    CONF
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.blank_panes

    normal = @scene.capture.split("\n")

    assert_includes normal[0], 'pane 0 of a very',
                    "the title is not truncated at the box, so this window is " \
                    "not testing truncation\n\n#{normal.join("\n")}"

    @scene.display_panes
    overlaid = @scene.capture
    assert_overlay_drawn overlaid

    # Row 0 is the top of the boxes on the window edge, row 6 the top of the
    # boxes below them, which is inside the overlay's own screen.
    [0, 6].each do |row|
      assert_equal normal[row], overlaid.split("\n")[row],
                   "display-panes drew border row #{row} differently\n\n" \
                   "normal:\n#{normal.join("\n")}\noverlay:\n#{overlaid}"
    end
  end

  # pane-border-indicators arrows marks the active pane's box with one arrow per
  # side. The overlay redraws the borders and draws none of them.
  def test_the_overlay_draws_pane_border_indicator_arrows
    two_pane_scene(<<~CONF)
      set -w -g pane-border-lines single
      set -g pane-border-indicators arrows
    CONF

    normal = @scene.capture
    drawn = ARROWS.select { |arrow| normal.include?(arrow) }

    refute_empty drawn,
                 "pane-border-indicators arrows draws no arrows at all\n\n" \
                 "#{normal}"

    @scene.display_panes
    overlaid = @scene.capture
    assert_overlay_drawn overlaid

    missing = drawn.reject { |arrow| overlaid.include?(arrow) }

    assert_empty missing,
                 "display-panes dropped the indicator arrows " \
                 "#{missing.join(' ')}\n\nnormal:\n#{normal}\n" \
                 "overlay:\n#{overlaid}"
  end
end
