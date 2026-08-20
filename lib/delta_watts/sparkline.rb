# frozen_string_literal: true

module DeltaWatts
  class Sparkline
    BLOCKS = "▁▂▃▄▅▆▇█".chars.freeze

    def initialize(samples, width:, tick: 0, charging: false)
      @samples = samples
      @width = width
      @tick = tick
      @charging = charging
    end

    def render
      return Ansi.color(:muted, "·" * @width) if @samples.empty?

      values = downsample(@samples, @width)
      min = values.min
      max = values.max
      range = max - min
      last_index = values.length - 1

      values.each_with_index.map do |value, index|
        block =
          if range.zero?
            BLOCKS[3]
          else
            block_index = ((value - min) / range * (BLOCKS.length - 1)).round
            BLOCKS[block_index]
          end

        color_for(value, min, max, index == last_index)
      end.join
    end

    private

    def color_for(value, min, max, latest)
      range = max - min
      t = range.zero? ? 0.5 : (value - min) / range

      base = if @charging
               Ansi.lerp_rgb([72, 118, 168], [102, 214, 152], t)
             else
               Ansi.lerp_rgb([168, 118, 88], [232, 128, 96], t)
             end

      if latest
        r, g, b = base
        Ansi.rgb(
          [r + 24, 255].min,
          [g + 24, 255].min,
          [b + 24, 255].min,
          block_for(value, min, max, range)
        )
      else
        Ansi.rgb(*base, block_for(value, min, max, range))
      end
    end

    def block_for(value, min, max, range)
      if range.zero?
        BLOCKS[3]
      else
        index = ((value - min) / range * (BLOCKS.length - 1)).round
        BLOCKS[index]
      end
    end

    def downsample(samples, width)
      return samples if samples.length <= width

      chunk_size = samples.length.to_f / width
      Array.new(width) do |index|
        start_at = (index * chunk_size).floor
        finish_at = [((index + 1) * chunk_size).floor, samples.length].min
        slice = samples[start_at...finish_at]
        slice.sum / slice.length.to_f
      end
    end
  end
end
