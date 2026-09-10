import {
  DataKind,
  Defaults,
  Envelope,
  LeftScope,
  LeftScope_Item,
  RightScope,
  RightScope_Item,
  Tensor,
  TensorDataOneofCase,
  View,
} from "./codec_regressions_lite.js";

declare const process: { argv: string[] };

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function equal(actual: unknown, expected: unknown, message: string): void {
  assert(Object.is(actual, expected), `${message}: got ${String(actual)}, expected ${String(expected)}`);
}

function bytes(actual: Uint8Array | undefined, expected: Uint8Array, message: string): void {
  assert(actual instanceof Uint8Array, `${message}: expected bytes`);
  equal(Array.from(actual).join(","), Array.from(expected).join(","), message);
}

const minified = process.argv.includes("--minified");
if (minified) {
  for (const [ctor, original] of [
    [Envelope, "Envelope"],
    [LeftScope_Item, "LeftScope_Item"],
    [RightScope_Item, "RightScope_Item"],
  ] as const) {
    assert(ctor.name !== original, `${original} must actually be renamed by the minifier`);
  }
}

for (const [ctor, fqn] of [
  [Envelope, "codec.regressions.Envelope"],
  [LeftScope, "codec.regressions.LeftScope"],
  [RightScope, "codec.regressions.RightScope"],
  [LeftScope_Item, "codec.regressions.LeftScope.Item"],
  [RightScope_Item, "codec.regressions.RightScope.Item"],
] as const) {
  equal(ctor.typeName, fqn, "canonical protobuf message name");
}
equal(LeftScope.fields[0].messageType, LeftScope_Item.typeName, "left item field FQN");
equal(RightScope.fields[0].messageType, RightScope_Item.typeName, "right item field FQN");
equal(Envelope.fields[0].messageType, LeftScope.typeName, "envelope left field FQN");
equal(Envelope.fields[1].messageType, RightScope.typeName, "envelope right field FQN");
equal(Envelope.fields[2].messageType, LeftScope_Item.typeName, "repeated item field FQN");

// Plain objects exercise registry lookup during encoding as well as decoding.
// The generated constructor accepts Partial<T>, so nested structural inputs
// require casts even though the codec supports them at runtime.
const nested = new Envelope({
  left: { item: { value: "left item" } } as LeftScope,
  right: { item: { value: 73 } } as RightScope,
  items: [{ value: "repeated item" } as LeftScope_Item],
});
// Unknown field 511 (varint) must be skipped before decoding known field tags
// through each nested class's own field-number table.
const decodedNested = Envelope.fromBinary(Uint8Array.from([0xf8, 0x1f, 123, ...nested.toBinary()]));
assert(decodedNested.left instanceof LeftScope, "left scope decoded as its registered class");
assert(decodedNested.right instanceof RightScope, "right scope decoded as its registered class");
assert(decodedNested.left.item instanceof LeftScope_Item, "left Item uses its own scope");
assert(decodedNested.right.item instanceof RightScope_Item, "right Item uses its own scope");
equal(decodedNested.left.item.value, "left item", "left nested payload");
equal(decodedNested.right.item.value, 73, "right nested payload");
equal(decodedNested.items.length, 1, "repeated nested length");
assert(decodedNested.items[0] instanceof LeftScope_Item, "repeated Item uses its registered class");
equal(decodedNested.items[0].value, "repeated item", "repeated nested payload");

type DataProperty = "inline" | "view" | "count" | "flag" | "text" | "position" | "kind";
const cases: readonly [DataProperty, TensorDataOneofCase, Tensor[DataProperty]][] = [
  ["inline", TensorDataOneofCase.Inline, Uint8Array.of(0, 128, 255)],
  ["inline", TensorDataOneofCase.Inline, new Uint8Array()],
  ["view", TensorDataOneofCase.View, new View({ offset: 7, length: 11 })],
  ["count", TensorDataOneofCase.Count, 0],
  ["flag", TensorDataOneofCase.Flag, false],
  ["text", TensorDataOneofCase.Text, ""],
  ["position", TensorDataOneofCase.Position, 0n],
  ["kind", TensorDataOneofCase.Kind, DataKind.DATA_KIND_UNSPECIFIED],
];

function payload(actual: Tensor[DataProperty], expected: Tensor[DataProperty], message: string): void {
  if (expected instanceof Uint8Array) {
    assert(actual instanceof Uint8Array, `${message}: expected bytes`);
    bytes(actual, expected, message);
  } else if (expected instanceof View) {
    assert(actual instanceof View, `${message}: expected View`);
    equal(actual.offset, expected.offset, `${message} offset`);
    equal(actual.length, expected.length, `${message} length`);
  } else {
    equal(actual, expected, message);
  }
}

for (const [prop, selectedCase, value] of cases) {
  const original = new Tensor({ [prop]: value });
  equal(original.dataCase, selectedCase, `${prop}: infer selector from supplied value`);
  const wire = original.toBinary();
  assert(wire.length > 0, `${prop}: selected default payload must be encoded`);
  const decoded = Tensor.fromBinary(wire);
  equal(decoded.dataCase, selectedCase, `${prop}: decoded selector`);
  payload(decoded[prop], value, `${prop}: decoded payload`);
  for (const field of Tensor.fields) {
    if (field.prop !== prop) {
      assert(Object.prototype.hasOwnProperty.call(decoded, field.prop), `${field.prop}: materialized absent field`);
      equal(decoded[field.prop as DataProperty], undefined, `${field.prop}: absent value`);
    }
  }
  const copied = new Tensor(decoded);
  equal(copied.dataCase, selectedCase, `${prop}: copied selector`);
  payload(copied[prop], value, `${prop}: copied payload`);
  const copiedWire = copied.toBinary();
  bytes(copiedWire, wire, `${prop}: copied wire payload`);
  const decodedAgain = Tensor.fromBinary(copiedWire);
  equal(decodedAgain.dataCase, selectedCase, `${prop}: reserialized selector`);
  payload(decodedAgain[prop], value, `${prop}: reserialized payload`);
}

const inline = Uint8Array.of(4, 5, 6);
const view = new View({ offset: 9, length: 3 });
for (const selectedCase of [TensorDataOneofCase.Inline, TensorDataOneofCase.View, TensorDataOneofCase.None]) {
  const explicit = new Tensor({ inline, view, dataCase: selectedCase });
  equal(explicit.dataCase, selectedCase, "explicit selector overrides stale payloads");
  const copied = new Tensor(explicit);
  equal(copied.dataCase, selectedCase, "copy preserves explicit selector including None");
  const decoded = Tensor.fromBinary(copied.toBinary());
  equal(decoded.dataCase, selectedCase, "explicit selector survives serialization");
  if (selectedCase === TensorDataOneofCase.Inline) bytes(decoded.inline, inline, "explicit inline payload");
  if (selectedCase === TensorDataOneofCase.View) payload(decoded.view, view, "explicit view payload");
  if (selectedCase === TensorDataOneofCase.None) equal(copied.toBinary().length, 0, "None ignores stale data");
}

// A valid wire stream may contain multiple oneof members. The last one wins,
// even when an earlier member still has a non-undefined property after decode.
const viewWire = new Tensor({ view }).toBinary();
const inlineWire = new Tensor({ inline }).toBinary();
const lastWins = Tensor.fromBinary(Uint8Array.from([...viewWire, ...inlineWire]));
equal(lastWins.dataCase, TensorDataOneofCase.Inline, "last wire member selects inline");
const lastWinsCopy = new Tensor(lastWins);
equal(lastWinsCopy.dataCase, TensorDataOneofCase.Inline, "copy preserves last wire member");
bytes(lastWinsCopy.toBinary(), inlineWire, "copy serializes only selected wire member");

const absent = new Tensor({ inline: undefined, view: undefined, kind: undefined });
equal(absent.dataCase, TensorDataOneofCase.None, "undefined does not select a oneof member");
equal(absent.toBinary().length, 0, "undefined oneof fields stay absent");
const inferred = new Tensor({ inline, view: undefined, kind: undefined, dataCase: undefined });
equal(inferred.dataCase, TensorDataOneofCase.Inline, "undefined selector and fields do not override inline");
bytes(inferred.inline, inline, "inferred inline data preserved");

const defaults = new Defaults({
  count: undefined,
  flag: undefined,
  text: undefined,
  position: undefined,
  sizes: undefined,
  optionalCount: undefined,
});
equal(defaults.count, 0, "undefined preserves numeric default");
equal(defaults.flag, false, "undefined preserves boolean default");
equal(defaults.text, "", "undefined preserves string default");
equal(defaults.position, 0n, "undefined preserves bigint default");
equal(defaults.sizes.length, 0, "undefined preserves repeated default");
equal(defaults.toBinary().length, 0, "undefined fields do not gain presence");

console.log(`TypeScript codec regressions passed (${minified ? "minified" : "ES2020"}).`);
