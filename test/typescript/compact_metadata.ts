import {
  Exclude,
  Excluded,
  Keywords,
  Metadata,
  MetadataFields,
  MetadataSelectionOneofCase,
  Nested,
  NoFields,
  NoFieldsFields,
  Status,
} from "./compact_metadata_lite.js";

declare const process: { argv: string[] };

function assert(condition: unknown, label: string): asserts condition {
  if (!condition) throw new Error(label);
}

function bytes(actual: Uint8Array, expected: number[], label: string): void {
  assert(actual.length === expected.length && actual.every((value, index) => value === expected[index]), label);
}

const minified = process.argv.includes("--minified");
if (minified) assert(Metadata.name !== "Metadata", "the minifier must rename the message");

const requestField: 1 = MetadataFields.request_id;
const ready: typeof Status.STATUS_READY = Status.STATUS_READY;
const countCase: typeof MetadataSelectionOneofCase.Count = MetadataSelectionOneofCase.Count;
const keyword: typeof Keywords.string = Keywords.string;
assert(requestField === 1 && ready === 1 && countCase === 8 && keyword === 1, "literal value types");
assert(Status.STATUS_ALIAS === 1 && Status[1] === "STATUS_ALIAS", "enum alias reverse lookup");
assert(Status.STATUS_REJECTED === -1 && Status[-1] === "STATUS_REJECTED", "negative enum lookup");
assert(Keywords.default === 2 && Keywords.constructor === 3, "reserved object keys");
assert(Object.prototype.hasOwnProperty.call(Keywords, "__proto__") && Keywords.__proto__ === 4,
  "__proto__ is an own enum member");
assert(Keywords[4] === "__proto__" && Object.getPrototypeOf(Keywords) === Object.prototype,
  "enum expansion preserves the object prototype");

const value = new Metadata({ requestId: 150n, uRLValue: "U", snakeName: "s", explicitZero: 0, count: 0, status: Status.STATUS_READY });
const wire = [8, 150, 1, 18, 1, 85, 26, 1, 115, 32, 0, 64, 0, 80, 1];
bytes(value.toBinary(), wire, "field numbers, names and explicit zero presence");
assert(JSON.stringify(value.toJson()) === JSON.stringify({
  requestId: "150", URLValue: "U", snakeName: "s", ExplicitZero: 0, count: 0, status: "STATUS_ALIAS",
}), "JSON names can differ from TypeScript properties");
const copied = Metadata.fromBinary(Uint8Array.from(wire));
assert(copied.requestId === 150n && copied.uRLValue === "U" && copied.explicitZero === 0,
  "decoder uses expanded field metadata");
bytes(new Metadata(copied).toBinary(), wire, "constructor copy retains presence and oneof selection");

const url = Metadata.fields.find(field => field.no === 2)!;
assert(url.name === "URL_value" && url.jsonName === "URLValue" && url.prop === "uRLValue",
  "reflection retains distinct proto, JSON and TypeScript names");
const optional = Metadata.fields.find(field => field.no === 4)!;
assert(optional.optional === true && optional.oneof === undefined && optional.prop === "explicitZero",
  "synthetic optional oneof stays optional");
const statuses = Metadata.fields.find(field => field.no === 5)!;
assert(statuses.repeated === true && statuses.enumType === Status, "repeated enum metadata");
const nestedField = Metadata.fields.find(field => field.no === 7)!;
assert(nestedField.messageType === Nested.typeName, "nested type identity");
const selection = Metadata.fields.find(field => field.no === 8)!;
assert(selection.oneof === "selectionCase" && selection.oneofCase === countCase, "oneof case equals its field number");
assert(JSON.stringify(MetadataFields) === JSON.stringify({
  request_id: 1, URL_value: 2, snake__name: 3, _explicit_zero: 4, statuses: 5,
  payload: 6, nested: 7, count: 8, label: 9, status: 10,
}), "public field-number table");
assert(NoFields.fields.length === 0 && Object.keys(NoFieldsFields).length === 0, "empty schema tables");

const enumValues = new Metadata({ statuses: [Status.STATUS_READY, Status.STATUS_REJECTED], status: 99 as Status });
const enumCopy = Metadata.fromBinary(enumValues.toBinary());
assert(enumCopy.statuses[0] === 1 && enumCopy.statuses[1] === -1 && Number(enumCopy.status) === 99,
  "aliases, negative values and unknown enum values roundtrip");
assert(JSON.stringify(enumCopy.toJson()) === JSON.stringify({ statuses: ["STATUS_ALIAS", "STATUS_REJECTED"], status: 99 }),
  "enum JSON names and unknown numeric values");
const exclusion: Exclude = Exclude.EXCLUDE_SELECTED;
const exclusionMember: 1 = Exclude.EXCLUDE_SELECTED;
const excluded = new Excluded({ exclusion });
bytes(excluded.toBinary(), [8, 1], "enum named Exclude encodes its numeric value");
const excludedCopy = Excluded.fromBinary(excluded.toBinary());
assert(excludedCopy.exclusion === exclusionMember && Exclude[exclusion] === "EXCLUDE_SELECTED",
  "enum named Exclude retains value types and reverse lookup");
assert(JSON.stringify(excludedCopy.toJson()) === JSON.stringify({ exclusion: "EXCLUDE_SELECTED" }),
  "enum named Exclude retains JSON conversion");
const nested = new Metadata({ nested: new Nested({ value: "child" }) });
const nestedCopy = Metadata.fromBinary(nested.toBinary());
assert(nestedCopy.nested instanceof Nested && nestedCopy.nested.value === "child", "nested decoder after minification");
assert(new Metadata().statuses !== new Metadata().statuses, "constructors own their mutable defaults");

function checkTypes(): void {
  // @ts-expect-error uint64 fields require bigint.
  new Metadata({ requestId: "150" });
  // @ts-expect-error JSON names do not replace TypeScript property names.
  new Metadata({ URLValue: "U" });
  // @ts-expect-error Enum values are numeric.
  new Metadata({ status: "STATUS_READY" });
  // @ts-expect-error An enum named Exclude also retains its numeric value type.
  new Excluded({ exclusion: "EXCLUDE_SELECTED" });
  // @ts-expect-error Field-number constants remain readonly.
  MetadataFields.request_id = 2;
}
void checkTypes;

console.log(`Compact TypeScript metadata passed (${minified ? "minified" : "ES2020"}).`);
