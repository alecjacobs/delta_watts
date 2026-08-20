# frozen_string_literal: true

module DeltaWatts
  class Sparkline
    ROWS = 7
    PER_ROW = 2
    CAP = "▄"
    GAP = "·"
    AC_FILL = [72, 148, 168].freeze
    BATT_FILL = [196, 128, 96].freeze

    def initialize(samples, width:, ceiling:, charging: false, window_sec: 60)
      @samples = samples
      @width = [width, 1].max
      @ceiling = [ceiling.to_f, 1.0].max
      @charging = charging
      @window_sec = [window_sec.to_f, 1.0].max
    end

    def render_rows
      slots = timed_window
      kinds = slots.map { |value| cells_for(value) }
      rgb = @charging ? AC_FILL : BATT_FILL

      ROWS.times.map do |row|
        paint_row(kinds, row, rgb)
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
      return Array.new(ROWS - 1, :empty) + [:gap] if value.nil?

      total = ROWS * PER_ROW
      filled = ((value.to_f / @ceiling).clamp(0.0, 1.0) * total).round
      filled = 1 if value.positive? && filled.zero?

      ROWS.times.map do |row_from_top|
        lower = (ROWS - 1 - row_from_top) * PER_ROW
        case (filled - lower).clamp(0, 2)
        when 2 then :fill
        when 1 then :cap
        else :empty
        end
      end
    end

    def paint_row(kinds, row, rgb)
      out = +""
      index = 0
      while index < kinds.length
        kind = kinds[index][row]
        if kind == :fill
          run = index
          run += 1 while run < kinds.length && kinds[run][row] == :fill
          out << Ansi.bg_rgb(*rgb, " " * (run - index))
          index = run
        else
          out << case kind
                 when :cap then Ansi.rgb(*rgb, CAP)
                 when :gap then Ansi.color(:bar_empty, GAP)
                 else " "
                 end
          index += 1
        end
      end
      out
    end
  end
end
