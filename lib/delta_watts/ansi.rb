# frozen_string_literal: true

module DeltaWatts
  module Ansi
    module_function

    RESET = "\e[0m"
    DIM = "\e[2m"
    BOLD = "\e[1m"
    HIDE_CURSOR = "\e[?25l"
    SHOW_CURSOR = "\e[?25h"
    ALT_SCREEN_ON = "\e[?1049h"
    ALT_SCREEN_OFF = "\e[?1049l"
    CLEAR = "\e[2J"
    HOME = "\e[H"
    ERASE_LINE = "\e[K"
    ERASE_LINE_FULL = "\e[2K"
    ERASE_DOWN = "\e[J"
    WRAP_OFF = "\e[?7l"
    WRAP_ON = "\e[?7h"
    SET_TITLE = "\e]0;Δ Watts\a"
    RESET_TITLE = "\e]0;\a"

    def cursor_at(row, col = 1)
      "\e[#{row};#{col}H"
    end

    PALETTE = {
      fg: "\e[38;5;252m",
      muted: "\e[38;5;245m",
      accent: "\e[38;5;81m",
      title: "\e[38;5;117m",
      good: "\e[38;5;114m",
      warn: "\e[38;5;221m",
      low: "\e[38;5;208m",
      critical: "\e[38;5;203m",
      charge: "\e[38;5;114m",
      discharge: "\e[38;5;210m",
      adapter: "\e[38;5;147m",
      bar_empty: "\e[38;5;238m",
      border: "\e[38;5;240m",
      bold: BOLD
    }.freeze

    CHARGE_PULSE = [114, 108, 102, 108].freeze
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    def truecolor?
      @truecolor = @truecolor.nil? ? detect_truecolor? : @truecolor
    end

    def detect_truecolor?
      term = ENV.fetch("TERM", "")
      colorterm = ENV.fetch("COLORTERM", "")
      return true if colorterm.match?(/truecolor|24bit/i)
      return true if term.match?(/ghostty|wezterm|alacritty|kitty|iterm|apple-terminal/i)

      $stdout.tty?
    end

    def color(name, text)
      "#{PALETTE.fetch(name)}#{text}#{RESET}"
    end

    def rgb(r, g, b, text)
      if truecolor?
        "\e[38;2;#{clamp_rgb(r)};#{clamp_rgb(g)};#{clamp_rgb(b)}m#{text}#{RESET}"
      else
        color(:accent, text)
      end
    end

    def pulse_color(base_rgb, tick, amplitude: 0.18)
      r, g, b = base_rgb
      wave = Math.sin(tick * Math::PI / 4)
      factor = 1.0 + (wave * amplitude)
      rgb((r * factor).round, (g * factor).round, (b * factor).round, "●")
    end

    def lerp(a, b, t)
      a + ((b - a) * t)
    end

    def lerp_rgb(from, to, t)
      [
        lerp(from[0], to[0], t).round,
        lerp(from[1], to[1], t).round,
        lerp(from[2], to[2], t).round
      ]
    end

    def battery_colors(percent)
      if percent <= 15
        { fill: [232, 95, 74], text: :critical }
      elsif percent <= 35
        { fill: [232, 168, 74], text: :low }
      elsif percent <= 60
        { fill: [120, 196, 130], text: :good }
      else
        { fill: [88, 196, 168], text: :charge }
      end
    end

    def strip_ansi(text)
      text.gsub(/\e\[[0-9;]*m/, "")
    end

    def visible_length(text)
      strip_ansi(text).length
    end

    def clamp_rgb(value)
      [[value.to_i, 0].max, 255].min
    end
  end
end
