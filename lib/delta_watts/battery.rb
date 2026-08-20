# frozen_string_literal: true

require "open3"

module DeltaWatts
  Snapshot = Struct.new(
    :percent,
    :voltage_mv,
    :amperage_ma,
    :is_charging,
    :external_connected,
    :fully_charged,
    :time_remaining_min,
    :time_to_full_min,
    :design_capacity_mah,
    :max_capacity_percent,
    :adapter_watts,
    keyword_init: true
  ) do
    def watts
      (amperage_ma * voltage_mv) / 1_000_000.0
    end

    def watts_into_battery
      return 0.0 unless external_connected && amperage_ma.positive?

      watts.abs
    end

    def watts_out_of_battery
      return 0.0 if external_connected && !amperage_ma.negative?

      watts.abs
    end

    def on_ac_power?
      external_connected
    end

    def charging?
      is_charging && !fully_charged
    end
  end

  class Battery
    FIELDS = {
      amperage_ma: "Amperage",
      voltage_mv: "Voltage",
      is_charging: "IsCharging",
      external_connected: "ExternalConnected",
      fully_charged: "FullyCharged",
      percent: "CurrentCapacity",
      time_remaining_min: "TimeRemaining",
      time_to_full_min: "AvgTimeToFull",
      instant_amperage_ma: "InstantAmperage",
      design_capacity_mah: "DesignCapacity",
      max_capacity_percent: "MaxCapacity",
      raw_current_mah: "AppleRawCurrentCapacity",
      raw_max_mah: "AppleRawMaxCapacity"
    }.freeze

    def self.snapshot
      new.read
    end

    def read
      raw = fetch_ioreg
      raise "No internal battery found on this Mac." if raw.nil? || raw.empty?

      values = parse_fields(raw)
      amperage = pick_amperage(values[:instant_amperage_ma], values[:amperage_ma])

      Snapshot.new(
        percent: values.fetch(:percent),
        voltage_mv: values.fetch(:voltage_mv),
        amperage_ma: amperage,
        is_charging: truthy?(values[:is_charging]),
        external_connected: truthy?(values[:external_connected]),
        fully_charged: truthy?(values[:fully_charged]),
        time_remaining_min: normalize_minutes(values[:time_remaining_min]) ||
          estimate_discharge_min(values[:raw_current_mah], amperage),
        time_to_full_min: normalize_minutes(values[:time_to_full_min]) ||
          estimate_charge_min(values[:raw_current_mah], values[:raw_max_mah], amperage),
        design_capacity_mah: values[:design_capacity_mah],
        max_capacity_percent: values[:max_capacity_percent],
        adapter_watts: parse_adapter_watts(raw)
      )
    end

    private

    def fetch_ioreg
      stdout, status = Open3.capture2("ioreg", "-l", "-w", "0", "-c", "AppleSmartBattery")
      return nil unless status.success?

      stdout.b
    end

    def parse_fields(raw)
      FIELDS.each_with_object({}) do |(key, label), result|
        next if key == :instant_amperage_ma

        match = raw.match(/"#{Regexp.escape(label)}" = (\S+)/)
        next unless match

        value = match[1]
        result[key] =
          case key
          when :is_charging, :external_connected, :fully_charged
            value
          when :percent, :time_remaining_min, :time_to_full_min,
               :design_capacity_mah, :max_capacity_percent,
               :raw_current_mah, :raw_max_mah
            value.to_i
          else
            value.to_i
          end
      end.tap do |result|
        instant = raw.match(/"InstantAmperage" = (\S+)/)
        result[:instant_amperage_ma] = instant[1].to_i if instant
      end
    end

    def parse_adapter_watts(raw)
      match = raw.match(/"Watts"=(\d+)/)
      return nil unless match

      match[1].to_i
    end

    def pick_amperage(instant, averaged)
      instant_ma = signed_ma(instant)
      return instant_ma unless instant_ma.zero?

      signed_ma(averaged)
    end

    # ioreg prints SInt64 InstantAmperage as unsigned when discharging.
    def signed_ma(value)
      return 0 if value.nil?

      value >= 2**63 ? value - 2**64 : value
    end

    def estimate_discharge_min(raw_mah, amperage_ma)
      return nil if raw_mah.nil? || raw_mah <= 0
      return nil unless amperage_ma.negative?

      ((raw_mah.to_f / amperage_ma.abs) * 60).round
    end

    def estimate_charge_min(raw_mah, raw_max_mah, amperage_ma)
      return nil if raw_mah.nil? || raw_max_mah.nil?
      return nil unless amperage_ma.positive?

      remaining = raw_max_mah - raw_mah
      return nil unless remaining.positive?

      ((remaining.to_f / amperage_ma) * 60).round
    end

    def truthy?(value)
      value == "Yes" || value == true
    end

    def normalize_minutes(value)
      return nil if value.nil?
      return nil if value.negative? || value >= 65_535

      value
    end
  end
end
