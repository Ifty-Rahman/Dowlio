export function browserName(navigator) {
  const brands = navigator?.userAgentData?.brands ?? [];
  const named = brands.map((entry) => entry.brand).find((brand) => !/not.?a.?brand|chromium/i.test(brand));
  return named ?? "Chromium";
}
