import CoreML
import Foundation

enum ProbeError: Error {
  case usage
  case missingOutput(String)
  case nonFiniteOutput(String)
}

func elapsed(_ operation: () throws -> Void) rethrows -> Double {
  let start = ProcessInfo.processInfo.systemUptime
  try operation()
  return ProcessInfo.processInfo.systemUptime - start
}

func summarize(_ array: MLMultiArray, name: String) throws -> [String: Any] {
  var minimum = Double.infinity
  var maximum = -Double.infinity
  for index in 0..<array.count {
    let value = array[index].doubleValue
    guard value.isFinite else { throw ProbeError.nonFiniteOutput(name) }
    minimum = min(minimum, value)
    maximum = max(maximum, value)
  }
  return [
    "shape": array.shape.map(\.intValue),
    "count": array.count,
    "minimum": minimum,
    "maximum": maximum,
  ]
}

guard CommandLine.arguments.count == 2 else { throw ProbeError.usage }
let modelURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let configuration = MLModelConfiguration()
configuration.computeUnits = .all

var model: MLModel!
let loadSeconds = try elapsed {
  model = try MLModel(contentsOf: modelURL, configuration: configuration)
}
let input = try MLMultiArray(shape: [1, 3, 800, 800], dataType: .float32)
input.dataPointer.bindMemory(to: Float32.self, capacity: input.count)
  .initialize(repeating: 0, count: input.count)
let provider = try MLDictionaryFeatureProvider(dictionary: [
  "pixel_values": MLFeatureValue(multiArray: input)
])

var output: MLFeatureProvider!
let firstPredictionSeconds = try elapsed {
  output = try model.prediction(from: provider)
}
let secondPredictionSeconds = try elapsed {
  output = try model.prediction(from: provider)
}

var summaries: [String: Any] = [:]
for name in ["class_logits", "boxes_cxcywh", "order_logits"] {
  guard let array = output.featureValue(for: name)?.multiArrayValue else {
    throw ProbeError.missingOutput(name)
  }
  summaries[name] = try summarize(array, name: name)
}

let report: [String: Any] = [
  "model": modelURL.path,
  "load_seconds": loadSeconds,
  "first_prediction_seconds": firstPredictionSeconds,
  "second_prediction_seconds": secondPredictionSeconds,
  "outputs": summaries,
]
let data = try JSONSerialization.data(
  withJSONObject: report,
  options: [.prettyPrinted, .sortedKeys]
)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
