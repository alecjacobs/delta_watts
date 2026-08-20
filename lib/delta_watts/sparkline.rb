# frozen_string_literal: true

module DeltaWatts
  class Sparkline
    ROWS = 3
    LEVELS = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"].freeze
    PER_ROW = LEVELS.length - 1
    GAP = "·"

    def initialize(samples, width:, ceiling:, charging: false)
      @samples = samples
      @width = [width, 1].max
      @ceiling = [ceiling.to_f, 1.0].max
      @charging = charging
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

    # Oldest on the left, now on the right. Unfilled time stays empty.
    def timed_window
      values = @samples.length > @width ? downsample(@samples, @width) : @samples
      Array.new(@width - values.length, nil) + values
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

    def downsample(samples, width)
      chunk_size = samples.length.to_f / width
      Array.new(width) do |index|
        start_at = (index * chunk_size).floor
        finish_at = [((index + 1) * chunk_size).floor, samples.length].min
        finish_at = start_at + 1 if finish_at <= start_at
        slice = samples[start_at...finish_at]
        slice.sum / slice.length.to_f
      end
    end
  end
end
