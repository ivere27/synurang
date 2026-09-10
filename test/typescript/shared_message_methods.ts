import {
  Choice,
  ChoiceValueOneofCase,
  Empty,
  Exclude,
  ExcludeSelectionOneofCase,
  Message,
  ProtoMessage,
} from "./shared_message_methods_lite.js";

declare const process: { argv: string[] };

function assert(condition: unknown, label: string): asserts condition {
  if (!condition) throw new Error(label);
}

function bytes(actual: Uint8Array, expected: Uint8Array, label: string): void {
  assert(actual.length === expected.length && actual.every((value, index) => value === expected[index]), label);
}

const minified = process.argv.includes("--minified");
if (minified) assert(Message.name !== "Message", "the minifier must actually rename the message");
assert(Message.typeName === "shared.methods.Message", "protobuf identity survives renaming");

for (const name of ["toBinary", "toByteArray", "toJson"] as const) {
  assert(Message.prototype[name] === Choice.prototype[name], `${name} shares one implementation`);
  assert(Empty.prototype[name] === ProtoMessage.prototype[name], `${name} also serves empty and nested messages`);
}

// A fixed wire oracle catches constructor values/presence overwritten by
// derived field initializers after introducing the shared base.
const message = new Message({ requestId: 150n, tags: ["a"], optionalCount: 0, raw: Uint8Array.of(0, 255) });
const wire = Uint8Array.of(8, 150, 1, 18, 1, 97, 24, 0, 34, 2, 0, 255);
bytes(message.toBinary(), wire, "constructor values and explicit optional zero survive initialization");
bytes(message.toByteArray(), wire, "toByteArray alias");
assert(JSON.stringify(message.toJson()) === JSON.stringify({
  requestId: "150", tags: ["a"], optionalCount: 0, raw: "AP8=",
}), "shared JSON conversion uses this message's fields");

// Static decoder callbacks retain their concrete return type and constructor,
// including calls without a receiver and Array.map's extra arguments.
const decode: (data: Uint8Array) => Message = Message.fromBinary;
const parse: (data: Uint8Array) => Message = Message.parseFrom;
const decoded: Message = decode(wire);
assert(decoded instanceof Message && decoded.requestId === 150n, "detached fromBinary");
assert(parse(wire) instanceof Message, "detached parseFrom");
const mapped: Message[] = [wire, wire].map(Message.fromBinary);
assert(mapped.every(value => value instanceof Message && value.optionalCount === 0), "typed decoder callback");
bytes(new Message(decoded).toBinary(), wire, "copy decoded fields and presence");
// @ts-expect-error Decoding preserves the concrete message type, not any/base.
const wrongType: Choice = Message.fromBinary(wire);
void wrongType;

const first = new Message(), second = new Message();
first.tags.push("private");
assert(second.tags.length === 0, "each message owns its mutable defaults");
bytes(second.toBinary(), new Uint8Array(), "default fields remain absent");
const undefinedFields = new Message({ requestId: undefined, tags: undefined, optionalCount: undefined });
assert(undefinedFields.requestId === 0n && undefinedFields.tags.length === 0, "undefined preserves defaults");
bytes(undefinedFields.toBinary(), new Uint8Array(), "undefined does not acquire presence");

const choice = new Choice({ count: 0 });
assert(choice.valueCase === ChoiceValueOneofCase.Count, "oneof selector initialized after its default");
bytes(choice.toBinary(), Uint8Array.of(8, 0), "selected zero oneof value is encoded");
const choiceCopy: Choice = Choice.parseFrom(choice.toByteArray());
assert(choiceCopy instanceof Choice && choiceCopy.valueCase === ChoiceValueOneofCase.Count, "oneof decoder uses its own type");
bytes(new Choice(choiceCopy).toBinary(), Uint8Array.of(8, 0), "oneof constructor copy");

const nested = new ProtoMessage({ message, messages: [message] });
const nestedCopy: ProtoMessage = ProtoMessage.fromBinary(nested.toBinary());
assert(nestedCopy.message instanceof Message && nestedCopy.messages[0] instanceof Message, "nested registry decoders");
bytes(nestedCopy.message.toBinary(), wire, "nested payload");
assert(Empty.fromBinary(new Uint8Array()) instanceof Empty, "empty decoder uses its own constructor");
bytes(new Empty().toByteArray(), new Uint8Array(), "empty shared encoder");

const objectFields = new Exclude({
  toString: "s",
  valueOf: [2, 3],
  hasOwnProperty: new Message({ requestId: 7n }),
  isPrototypeOf: Uint8Array.of(1, 255),
  propertyIsEnumerable: 0,
  toLocaleString: "",
});
const objectWire = Uint8Array.of(10, 1, 115, 18, 2, 2, 3, 26, 2, 8, 7, 34, 2, 1, 255, 40, 0, 50, 0);
bytes(objectFields.toBinary(), objectWire, "Object member field names preserve binary encoding and explicit zero presence");
const objectCopy: Exclude = Exclude.parseFrom(objectWire);
assert(objectCopy.toString === "s" && objectCopy.valueOf.join(",") === "2,3",
  "scalar and repeated fields can use Object member names");
assert(objectCopy.hasOwnProperty instanceof Message && objectCopy.hasOwnProperty.requestId === 7n,
  "message fields can use Object member names");
assert(objectCopy.isPrototypeOf instanceof Uint8Array, "bytes field retains its concrete type");
bytes(objectCopy.isPrototypeOf, Uint8Array.of(1, 255), "bytes fields can use Object member names");
assert(objectCopy.propertyIsEnumerable === 0 && objectCopy.toLocaleString === "" &&
  objectCopy.selectionCase === ExcludeSelectionOneofCase.ToLocaleString,
  "optional and oneof Object member fields retain selected defaults");
assert(JSON.stringify(objectCopy.toJson()) === JSON.stringify({
  toString: "s", valueOf: [2, 3], hasOwnProperty: { requestId: "7" }, isPrototypeOf: "Af8=",
  propertyIsEnumerable: 0, toLocaleString: "",
}), "Object member field names preserve JSON conversion");
bytes(new Exclude(objectCopy).toByteArray(), objectWire, "copy preserves Object member fields and presence");

for (const name of ["fromBinary", "parseFrom"] as const) {
  const descriptor = Object.getOwnPropertyDescriptor(Message, name)!;
  assert(!descriptor.enumerable && descriptor.writable && descriptor.configurable, `${name} retains static method descriptors`);
}
const originalDecode = Message.fromBinary;
let calls = 0;
try {
  Message.fromBinary = data => { calls++; return originalDecode(data); };
  assert(parse(wire) instanceof Message && calls === 1, "parseFrom delegates to the current fromBinary");
} finally {
  Message.fromBinary = originalDecode;
}

console.log(`Shared TypeScript message methods passed (${minified ? "minified" : "ES2020"}).`);
