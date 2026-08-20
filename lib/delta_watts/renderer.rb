# frozen_string_literal: true

module DeltaWatts
  class Renderer
    def initialize(width:, height:)
      @width = [width, 60].max
      @height = height
    end

    def render(snapshot:, history:, interval_sec:, tick:, display_percent:)
      inner = @width - 4
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
      lines.join("\n")
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
      bar_width = inner - 14
      bar_width = [bar_width, 20].max
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

      col_width = (inner - 5) / 2
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

    def history_section(snapshot, history, inner, interval_sec, tick)
      label = snapshot_label(interval_sec)
      spark_width = inner - 2
      spark = Sparkline.new(
        history,
        width: spark_width,
        tick: tick,
        charging: snapshot.on_ac_power?
      ).render
      stats = history_stats(history, snapshot)

      [
        bordered(Ansi.color(:muted, label), inner),
        bordered("  #{spark}", inner),
        bordered(stats, inner)
      ]
    end

    def snapshot_label(interval_sec)
      window = [60, interval_sec].max
      "Power (#{window}s)"
    end

    def history_stats(history, snapshot)
      return Ansi.color(:muted, "waiting for samples…") if history.empty?

      max = history.max
      avg = history.sum / history.length
      tone = snapshot.on_ac_power? ? [102, 178, 214] : [214, 152, 108]
      Ansi.rgb(*tone, format("max %.1f W · avg %.1f W", max, avg))
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
      padding = inner - Ansi.visible_length(content)
      padding = [padding, 0].max
      "#{border_vertical} #{content}#{" " * padding} #{border_vertical}"
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
      gap = inner - Ansi.visible_length(left) - Ansi.visible_length(right)
      gap = [gap, 1].max
      "#{left}#{" " * gap}#{right}"
    end
  end
end
