#pragma once

#include <nlohmann/json.hpp>

#include <optional>
#include <string>
#include <vector>

// Expected wire format:
// {
//   "device_id": "sensor-001",
//   "timestamp": "2026-09-09T12:34:56Z",
//   "temperature": 23.5,
//   "location": { "lat": 40.7128, "lon": -74.0060 }
// }
namespace telemetry::model {

struct Location {
    double lat;
    double lon;
};

struct TelemetryPayload {
    std::string deviceId;
    std::string timestamp; // Kept as the original ISO-8601 string; Postgres casts/validates it.
    double temperature;
    Location location;
};

// Validates the shape and types of an incoming payload and, if valid,
// parses it into a TelemetryPayload. On failure, returns std::nullopt
// and writes a human-readable reason to `error`.
//
// This function must never throw: it sits directly on the boundary
// between untrusted network input and the rest of the service, so any
// malformed/adversarial payload must be turned into a normal negative
// result, not an exception.
inline std::optional<TelemetryPayload> parseTelemetryPayload(const nlohmann::json& body, std::string& error) {
    if (!body.is_object()) {
        error = "Request body must be a JSON object";
        return std::nullopt;
    }

    static const std::vector<std::string> requiredFields = {
        "device_id", "timestamp", "temperature", "location"
    };
    for (const auto& field : requiredFields) {
        if (!body.contains(field)) {
            error = "Missing required field: '" + field + "'";
            return std::nullopt;
        }
    }

    if (!body["device_id"].is_string() || body["device_id"].get<std::string>().empty()) {
        error = "'device_id' must be a non-empty string";
        return std::nullopt;
    }
    // Loosely bound device_id length to avoid unbounded strings hitting the DB layer.
    if (body["device_id"].get<std::string>().size() > 128) {
        error = "'device_id' must be 128 characters or fewer";
        return std::nullopt;
    }

    if (!body["timestamp"].is_string() || body["timestamp"].get<std::string>().empty()) {
        error = "'timestamp' must be a non-empty ISO-8601 string, e.g. '2026-09-09T12:34:56Z'";
        return std::nullopt;
    }

    if (!body["temperature"].is_number()) {
        error = "'temperature' must be a number";
        return std::nullopt;
    }
    const double temperature = body["temperature"].get<double>();
    // Generous physical sanity bounds (Celsius) -- rejects obviously
    // corrupt sensor data without hardcoding a narrow "valid" range.
    if (temperature < -273.15 || temperature > 1000.0) {
        error = "'temperature' is outside a plausible range";
        return std::nullopt;
    }

    if (!body["location"].is_object()) {
        error = "'location' must be an object with numeric 'lat' and 'lon'";
        return std::nullopt;
    }
    const auto& loc = body["location"];
    if (!loc.contains("lat") || !loc.contains("lon") ||
        !loc["lat"].is_number() || !loc["lon"].is_number()) {
        error = "'location' must contain numeric 'lat' and 'lon'";
        return std::nullopt;
    }

    const double lat = loc["lat"].get<double>();
    const double lon = loc["lon"].get<double>();
    if (lat < -90.0 || lat > 90.0) {
        error = "'location.lat' must be between -90 and 90";
        return std::nullopt;
    }
    if (lon < -180.0 || lon > 180.0) {
        error = "'location.lon' must be between -180 and 180";
        return std::nullopt;
    }

    TelemetryPayload payload;
    payload.deviceId = body["device_id"].get<std::string>();
    payload.timestamp = body["timestamp"].get<std::string>();
    payload.temperature = temperature;
    payload.location = Location{lat, lon};
    return payload;
}

} // namespace telemetry::model
