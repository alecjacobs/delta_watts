# frozen_string_literal: true

module DeltaWatts
  class Sparkline
    ROWS = 7
    LEVELS = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"].freeze
    PER_ROW = LEVELS.length - 1
    GAP = "·"

    def initialize(samples, width:, ceiling:, charging: false, window_sec: 60)
      @samples = samples
      @width = [width, 1].max
      @ceiling = [ceiling.to_f, 1.0].max
      @charging = charging
      @window_sec = [window_sec.to_f, 1.0].max
    end

    def render_rows
      slots = timed_window
      last_sample = slots.rindex { |value| !value.nil? }

      columns = slots.each_with_index.map do |value, index|
        cells_for(value).map { |char| paint(char, value, index == last_sample) }
      end

      ROWS.times.map do |row|
        columns.map { |column| column[row] }.join
      end
    end

    private

    # Fixed time columns over [now - window, now]. A sample stays in the same
    # column until the window advances far enough to age it one slot left.
    def timed_window
      return Array.new(@width) if @samples.empty?

      now = @samples.last[0]
      dt = @window_sec / @width
      # Snap the left edge to dt so columns only shift when a full slot elapses.
      origin = ((now - @window_sec) / dt).floor * dt
      sums = Array.new(@width, 0.0)
      counts = Array.new(@width, 0)

      @samples.each do |at, watts|
        next if at < origin

        index = ((at - origin) / dt).floor
        index = @width - 1 if index >= @width
        next if index.negative?

        sums[index] += watts
        counts[index] += 1
      end

      slots = counts.each_index.map { |i| counts[i].positive? ? sums[i] / counts[i] : nil }
      fill_interior_gaps(slots)
    end

    def fill_interior_gaps(slots)
      first = slots.index { |value| !value.nil? }
      last = slots.rindex { |value| !value.nil? }
      return slots unless first && last

      prev = slots[first]
      (first..last).each do |index|
        if slots[index].nil?
          slots[index] = prev
        else
          prev = slots[index]
        end
      end
      slots
    end

    def cells_for(value)
      return Array.new(ROWS - 1, " ") + [GAP] if value.nil?

      total = ROWS * PER_ROW
      filled = ((value.to_f / @ceiling).clamp(0.0, 1.0) * total).round
      filled = 1 if value.positive? && filled.zero?

      ROWS.times.map do |row_from_top|
        lower = (ROWS - 1 - row_from_top) * PER_ROW
        LEVELS[(filled - lower).clamp(0, PER_ROW)]
      end
    end

    def paint(char, value, latest)
      return char if char == " "
      return Ansi.color(:bar_empty, char) if value.nil?

      t = (value / @ceiling).clamp(0.0, 1.0)
      base = if @charging
               Ansi.lerp_rgb([72, 118, 168], [102, 214, 152], t)
             else
               Ansi.lerp_rgb([168, 118, 88], [232, 128, 96], t)
             end

      if latest
        r, g, b = base
        Ansi.rgb([r + 20, 255].min, [g + 20, 255].min, [b + 20, 255].min, char)
      else
        Ansi.rgb(*base, char)
      end
    end
  end
end
