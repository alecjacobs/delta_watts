# frozen_string_literal: true

module DeltaWatts
  class Renderer
    AXIS_PREFIX = 7

    def initialize(width:, height:)
      @width = [width, 2].max
      @height = [height, 1].max
    end

    def render(snapshot:, history:, interval_sec:, tick:, display_percent:)
      inner = [@width - 4, 1].max
      lines = []
      lines << border_top
      lines << bordered(centered(title_text, inner), inner)
      lines << border_divider(inner)
      lines << bordered("", inner)
      lines.concat(status_section(snapshot, inner, tick))
      lines << bordered("", inner)
      lines.concat(battery_section(snapshot, inner, tick, display_percent))
      lines << bordered("", inner)
      lines.concat(metrics_section(snapshot, inner, tick))
      lines << bordered("", inner)
      lines.concat(history_section(snapshot, history, inner, interval_sec, tick))
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

    def battery_section(snapshot, inner, tick, display_percent)
      bar_width = [inner - 10, 4].max
      fill_width = (display_percent / 100.0 * bar_width).round
      fill_width = [[fill_width, 0].max, bar_width].min
      palette = Ansi.battery_colors(display_percent.round)
      bar = battery_bar(fill_width, bar_width, palette, snapshot.charging?, tick)
      percent_text = format("%3d%%", display_percent.round)
      percent = Ansi.rgb(*palette[:fill], percent_text)

      [
        bordered(Ansi.color(:muted, "Battery"), inner),
        bordered("  #{bar}  #{percent}", inner)
      ]
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

    def metrics_section(snapshot, inner, tick)
      left_title = snapshot.charging? ? "Charging" : "Runtime"
      right_title = snapshot.on_ac_power? ? "Power In" : "Power Out"

      left_value = time_value(snapshot, tick)
      right_value = power_value(snapshot)

      col_width = [(inner - 5) / 2, 1].max
      header = metric_header(left_title, right_title, col_width, snapshot)
      values = metric_values(left_value, right_value, col_width)

      [
        bordered(header, inner),
        bordered(values, inner)
      ]
    end

    def metric_header(left, right, col_width, snapshot)
      left_color = snapshot.charging? ? :charge : :muted
      right_color = snapshot.on_ac_power? ? :charge : :discharge
      left_text = Ansi.color(left_color, left.ljust(col_width))
      right_text = Ansi.color(right_color, right.rjust(col_width))
      "#{left_text}   #{right_text}"
    end

    def time_value(snapshot, tick)
      if snapshot.fully_charged
        Ansi.color(:good, "Complete")
      elsif snapshot.charging?
        text = format_duration(snapshot.time_to_full_min) || "Calculating…"
        muted = format_duration(snapshot.time_to_full_min).nil?
        muted ? charging_wait(tick) : Ansi.color(:fg, text)
      else
        text = format_duration(snapshot.time_remaining_min)
        text ? Ansi.color(:fg, text) : Ansi.color(:muted, "Calculating…")
      end
    end

    def charging_wait(tick)
      spinner = Ansi.color(:charge, Ansi::SPINNER[tick % Ansi::SPINNER.length])
      "#{spinner} #{Ansi.color(:muted, "Calculating…")}"
    end

    def power_value(snapshot)
      if snapshot.on_ac_power?
        watts = snapshot.watts_into_battery
        if snapshot.fully_charged
          Ansi.color(:muted, "0.0 W")
        else
          Ansi.rgb(102, 214, 152, format("%.1f W", watts))
        end
      else
        Ansi.rgb(232, 148, 108, format("%.1f W", snapshot.watts_out_of_battery))
      end
    end

    def history_section(snapshot, history, inner, interval_sec, _tick)
      ceiling = power_ceiling(snapshot, history)
      spark_width = [inner - AXIS_PREFIX, 1].max
      rows = Sparkline.new(
        history,
        width: spark_width,
        ceiling: ceiling,
        charging: snapshot.on_ac_power?
      ).render_rows
      ticks = y_ticks(ceiling)

      graph = rows.each_with_index.map do |row, index|
        bordered("#{axis_label(ticks[index])}#{row}", inner)
      end

      [
        bordered(history_header(snapshot, interval_sec, inner), inner),
        *graph,
        bordered(history_stats(history, snapshot), inner)
      ]
    end

    def history_header(snapshot, interval_sec, inner)
      window = [60, interval_sec].max
      left = Ansi.color(:muted, snapshot.on_ac_power? ? "Into battery" : "From battery")
      right = Ansi.color(:muted, "last #{window}s")
      pad_between(left, right, inner)
    end

    def y_ticks(ceiling)
      top = ceiling.round
      mid = (ceiling / 2.0).round
      [top, mid, 0].map { |watts| format("%3dW", watts) }
    end

    def axis_label(tick)
      "#{Ansi.color(:muted, tick)}#{Ansi.color(:border, " ┤ ")}"
    end

    def power_ceiling(snapshot, history)
      observed = history.max || 0.0
      adapter = snapshot.adapter_watts.to_f
      floor = 20.0
      if adapter.positive?
        [observed, adapter, floor].max
      else
        nice_ceiling([observed, floor].max)
      end
    end

    def nice_ceiling(value)
      step = value >= 50 ? 20.0 : 10.0
      (value / step).ceil * step
    end

    def history_stats(history, snapshot)
      prefix = " " * AXIS_PREFIX
      return "#{prefix}#{Ansi.color(:muted, "waiting for samples…")}" if history.empty?

      max = history.max
      avg = history.sum / history.length
      tone = snapshot.on_ac_power? ? [102, 178, 214] : [214, 152, 108]
      "#{prefix}#{Ansi.rgb(*tone, format("max %.1f W · avg %.1f W", max, avg))}"
    end

    def metric_values(left, right, col_width)
      left_plain = strip(left)
      right_plain = strip(right)
      left_pad = col_width - left_plain.length
      right_pad = col_width - right_plain.length
      "  #{left}#{" " * [left_pad, 0].max}   #{" " * [right_pad, 0].max}#{right}"
    end

    def strip(text)
      Ansi.strip_ansi(text)
    end

    def format_duration(minutes)
      return nil if minutes.nil?

      hours = minutes / 60
      mins = minutes % 60
      if hours.positive?
        format("%d:%02d", hours, mins)
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
