const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const optionalNumber = (value) => value == null || (typeof value === "number" && Number.isFinite(value));
const optionalDate = (value) => value == null ||
  (typeof value === "string" && value.length <= 64 && Number.isFinite(Date.parse(value)));

export function validSample(sample) {
  return isObject(sample) && typeof sample.id === "string" && sample.id.length > 0 && sample.id.length <= 256 &&
    Number.isFinite(sample.lat) && Math.abs(sample.lat) <= 90 &&
    Number.isFinite(sample.lon) && Math.abs(sample.lon) <= 180 &&
    optionalNumber(sample.accuracy) && optionalDate(sample.timestamp);
}

// These values are rendered in a diary read by the agent. Never interpolate
// arbitrary JSON strings/objects or multiline workout names into that context.
export function validHealth(health) {
  if (health == null) return true;
  if (!isObject(health) || !optionalDate(health.periodStart) || !optionalDate(health.periodEnd)) return false;
  const numberFields = [
    "steps", "activeEnergyKcal", "distanceMeters", "heartRateAvg", "heartRateMin", "heartRateMax",
    "restingHeartRate", "hrvAvgMs", "bloodOxygenPercent", "respiratoryRateAvg", "bodyMassKg",
    "bodyTemperatureCelsius", "wristTemperatureCelsius",
  ];
  if (!numberFields.every((field) => optionalNumber(health[field]))) return false;
  if (health.sleepMinutes != null && (!isObject(health.sleepMinutes) ||
      !["total", "deep", "rem", "core", "awake"].every((field) => optionalNumber(health.sleepMinutes[field])))) return false;
  if (health.workouts != null && (!Array.isArray(health.workouts) || health.workouts.length > 100 ||
      !health.workouts.every((workout) => isObject(workout) &&
        (workout.activityType == null || (typeof workout.activityType === "string" &&
          workout.activityType.length <= 128 && !/[\r\n\u2028\u2029]/.test(workout.activityType))) &&
        optionalNumber(workout.durationSeconds) && optionalNumber(workout.energyKcal)))) return false;
  return true;
}
