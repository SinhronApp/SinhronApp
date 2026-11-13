/// First 8 characters of an id for display ("Call · 3fa9c1d2"); ids
/// shorter than that are shown whole (substring would throw).
String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;
