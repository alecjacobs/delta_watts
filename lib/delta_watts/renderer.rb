# frozen_string_literal: true

module DeltaWatts
  class Renderer
    AXIS_PREFIX = 7
    CEILING_SNAPS = [5, 10, 20, 50, 100, 200, 400].freeze

    def initialize(width:, height:)
      @width = [width, 2].max
      @height = [height, 1].max
    end

    def render(snapshot:, history:, interval_sec:, tick:, display_percent:, power_watts:)
      inner = [@width - 4, 1].max
      lines = []
      lines << border_top
      lines << bordered(centered(title_text, inner), inner)
      lines << border_divider(inner)
      lines.concat(status_section(snapshot, inner, tick))
      lines << bordered("", inner)
      lines.concat(summary_section(snapshot, inner, tick, display_percent, power_watts))
      lines << bordered("", inner)
      lines.concat(history_section(snapshot, history, inner, interval_sec, power_watts))
      lines << bordered(Ansi.color(:muted, centered("q quit", inner)), inner)
      lines << border_bottom
      lines.map { |line| fit(line) }.join("\n")
    end

    private

    def title_text
      Ansi.color(:title, "Δ") + Ansi.color(:fg, " Watts")
    end

    def status_section(snapshot, inner, tick)
      status = power_status(snapshot)
      detail = adapter_detail(snapshot)
      [bordered(status_line(status, detail, inner, snapshot, tick), inner)]
    end

    def power_status(snapshot)
      if snapshot.on_ac_power?
        if snapshot.fully_charged
          { dot: :good, label: "AC Power", sublabel: "Fully charged", pulse: false }
        elsif snapshot.charging?
          { dot: :charge, label: "AC Power", sublabel: "Charging", pulse: true }
        else
          { dot: :accent, label: "AC Power", sublabel: "Connected", pulse: false }
        end
      else
        { dot: :warn, label: "Battery Power", sublabel: "Unplugged", pulse: false }
      end
    end

    def adapter_detail(snapshot)
      return nil unless snapshot.on_ac_power? && snapshot.adapter_watts

      Ansi.color(:adapter, "#{snapshot.adapter_watts}W adapter")
    end

    def status_line(status, detail, inner, snapshot, tick)
      dot = status_dot(status, snapshot, tick)
      label = Ansi.color(:fg, status[:label])
      sublabel = colored_sublabel(status[:sublabel], snapshot)
      left = "#{dot} #{label}  #{sublabel}"
      right = detail || ""
      pad_between(left, right, inner)
    end

    def status_dot(status, snapshot, tick)
      if snapshot.charging?
        base = [102, 214, 152]
        Ansi.pulse_color(base, tick, amplitude: 0.14)
      elsif snapshot.on_ac_power?
        Ansi.rgb(120, 178, 232, "●")
      elsif snapshot.percent <= 20
        Ansi.rgb(232, 120, 96, "●")
      else
        Ansi.rgb(232, 196, 108, "●")
      end
    end

    def colored_sublabel(text, snapshot)
      if snapshot.charging?
        Ansi.color(:charge, text)
      elsif snapshot.fully_charged
        Ansi.color(:good, text)
      elsif snapshot.on_ac_power?
        Ansi.color(:muted, text)
      else
        Ansi.color(:warn, text)
      end
    end

    def summary_section(snapshot, inner, tick, display_percent, power_watts)
      [bordered(summary_line(snapshot, inner, tick, display_percent, power_watts), inner)]
    end

    def summary_line(snapshot, inner, tick, display_percent, power_watts)
      runtime = compact_runtime(snapshot, tick)
      power = compact_power(snapshot, power_watts)
      palette = Ansi.battery_colors(display_percent.round)
      percent = Ansi.rgb(*palette[:fill], format("%3d%%", display_percent.round))
      metrics = "#{runtime}   #{power}"

      reserved = Ansi.visible_length(percent) + Ansi.visible_length(metrics) + 4
      bar_width = [inner - reserved, 6].max
      fill_width = (display_percent / 100.0 * bar_width).round.clamp(0, bar_width)
      bar = battery_bar(fill_width, bar_width, palette, snapshot.charging?, tick)

      pad_between("#{bar}  #{percent}", metrics, inner)
    end

    def battery_bar(filled, width, palette, charging, tick)
      if filled.zero?
        return Ansi.color(:bar_empty, "░" * width)
      end

      segments = Array.new(filled) do |index|
        if charging && index == (tick % filled)
          shimmer_char(palette[:fill], tick)
        elsif charging && index == filled - 1
          leading_edge(palette[:fill])
        else
          Ansi.rgb(*palette[:fill], "█")
        end
      end

      segments.join + Ansi.color(:bar_empty, "░" * (width - filled))
    end

    def shimmer_char(base_rgb, tick)
      r, g, b = base_rgb
      wave = Math.sin(tick * Math::PI / 3)
      Ansi.rgb(
        (r + 28 * wave).round.clamp(0, 255),
        (g + 28 * wave).round.clamp(0, 255),
        (b + 18 * wave).round.clamp(0, 255),
        "█"
      )
    end

    def leading_edge(base_rgb)
      r, g, b = base_rgb
      Ansi.rgb([r + 36, 255].min, [g + 36, 255].min, [b + 24, 255].min, "█")
    end

    def compact_runtime(snapshot, tick)
      if snapshot.fully_charged
        Ansi.color(:good, "Complete")
      elsif snapshot.charging?
        duration = format_duration(snapshot.time_to_full_min)
        if duration
          "#{Ansi.color(:fg, duration)} #{Ansi.color(:muted, "to full")}"
        else
          spinner = Ansi.color(:charge, Ansi::SPINNER[tick % Ansi::SPINNER.length])
          "#{spinner} #{Ansi.color(:muted, "to full")}"
        end
      else
        duration = format_duration(snapshot.time_remaining_min)
        if duration
          "#{Ansi.color(:fg, duration)} #{Ansi.color(:muted, "left")}"
        else
          Ansi.color(:muted, "Calculating…")
        end
      end
    end

    def compact_power(snapshot, power_watts)
      watts = power_watts.to_f
      value = if snapshot.on_ac_power?
                Ansi.rgb(102, 214, 152, format("%.1f W", watts))
              else
                Ansi.rgb(232, 148, 108, format("%.1f W", watts))
              end
      "#{value} #{Ansi.color(:muted, "draw")}"
    end

    def history_section(snapshot, history, inner, interval_sec, power_watts)
      ceiling = power_ceiling(history, power_watts)
      spark_width = [inner - AXIS_PREFIX, 1].max
      rows = Sparkline.new(
        history,
        width: spark_width,
        ceiling: ceiling,
        charging: snapshot.on_ac_power?,
        window_sec: interval_sec
      ).render_rows
      ticks = y_ticks(ceiling)

      graph = rows.each_with_index.map do |row, index|
        bordered("#{axis_label(ticks[index])}#{row}", inner)
      end

      [
        bordered(history_header(snapshot, interval_sec), inner),
        *graph,
        bordered(history_stats(history, snapshot), inner)
      ]
    end

    def history_header(_snapshot, interval_sec)
      window = [60, interval_sec].max
      Ansi.color(:muted, "Draw · last #{window}s")
    end

    def y_ticks(ceiling)
      rows = Sparkline::ROWS
      Array.new(rows) do |index|
        if index.zero?
          format("%3dW", ceiling.round)
        elsif index == rows / 2
          format("%3dW", (ceiling / 2.0).round)
        elsif index == rows - 1
          format("%3dW", 0)
        else
          "    "
        end
      end
    end

    def axis_label(tick)
      "#{Ansi.color(:muted, tick)}#{Ansi.color(:border, " ┤ ")}"
    end

    def power_ceiling(history, power_watts)
      observed = [watts_series(history).max || 0.0, power_watts.to_f].max
      nice_ceiling([observed * 1.25, CEILING_SNAPS.first].max)
    end

    def nice_ceiling(value)
      CEILING_SNAPS.find { |snap| snap >= value } || CEILING_SNAPS.last
    end

    def history_stats(history, snapshot)
      prefix = " " * AXIS_PREFIX
      values = watts_series(history)
      return "#{prefix}#{Ansi.color(:muted, "waiting for samples…")}" if values.empty?

      max = values.max
      avg = values.sum / values.length
      tone = snapshot.on_ac_power? ? [102, 178, 214] : [214, 152, 108]
      "#{prefix}#{Ansi.rgb(*tone, format("max %.1f W · avg %.1f W", max, avg))}"
    end

    def watts_series(history)
      history.map { |(_, watts)| watts }
    end

    def format_duration(minutes)
      return nil if minutes.nil?

      hours = minutes / 60
      mins = minutes % 60
      if hours.positive?
        format("%dh %dm", hours, mins)
      else
        format("%d min", mins)
      end
    end

    def bordered(content, inner)
      visible = Ansi.visible_length(content)
      if visible > inner
        content = truncate(content, inner)
        visible = Ansi.visible_length(content)
      end
      padding = [inner - visible, 0].max
      "#{border_vertical} #{content}#{" " * padding} #{border_vertical}"
    end

    def fit(text)
      Ansi.visible_length(text) <= @width ? text : truncate(text, @width)
    end

    def truncate(text, max)
      return text if Ansi.visible_length(text) <= max

      out = +""
      visible = 0
      text.scan(/\e\[[0-9;]*m|[^\e]/) do |token|
        break if visible >= max
        if token.start_with?("\e")
          out << token
        else
          out << token
          visible += 1
        end
      end
      out << Ansi::RESET
    end

    def border_top
      "#{corner(:tl)}#{horizontal(@width - 2)}#{corner(:tr)}"
    end

    def border_bottom
      "#{corner(:bl)}#{horizontal(@width - 2)}#{corner(:br)}"
    end

    def border_divider(inner)
      "#{border_vertical}#{horizontal(inner + 2, "─")}#{border_vertical}"
    end

    def horizontal(count, char = "─")
      Ansi.color(:border, char * count)
    end

    def border_vertical
      Ansi.color(:border, "│")
    end

    def corner(which)
      char = { tl: "╭", tr: "╮", bl: "╰", br: "╯" }.fetch(which)
      Ansi.color(:border, char)
    end

    def centered(text, inner)
      visible = Ansi.visible_length(text)
      left_pad = [(inner - visible) / 2, 0].max
      right_pad = [inner - visible - left_pad, 0].max
      "#{" " * left_pad}#{text}#{" " * right_pad}"
    end

    def pad_between(left, right, inner)
      left_len = Ansi.visible_length(left)
      right_len = Ansi.visible_length(right)
      if left_len + right_len + 1 > inner
        keep = [inner - right_len - 1, 0].max
        left = truncate(left, keep) if keep < left_len
        left_len = Ansi.visible_length(left)
      end
      gap = [inner - left_len - right_len, 1].max
      "#{left}#{" " * gap}#{right}"
    end
  end
end
