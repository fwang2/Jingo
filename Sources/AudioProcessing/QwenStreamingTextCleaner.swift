import Foundation

public enum QwenStreamingTextCleaner {
  public static func clean(_ text: String) -> String {
    var result = text

    // StreamingInferenceSession decodes Qwen's assistant prefix as ordinary text.
    // A prefix can be split between confirmed and provisional updates, so clean
    // complete markers as well as either incomplete half.
    result = result.replacingOccurrences(
      of: #"(?:^|\s)language\s+[^\s<]+<asr_text>"#,
      with: " ",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"(?:^|(?<=[.!?。！？]))\s*language(?:\s+[^\s<]*)?$"#,
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"^\s*[^\s<]+<asr_text>"#,
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(of: "<asr_text>", with: "")

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
