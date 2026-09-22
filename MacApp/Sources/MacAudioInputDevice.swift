import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// MARK: - MacAudioInputDevice

struct MacAudioInputDevice: Identifiable, Equatable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let name: String
  let isSystemDefault: Bool
  let transportType: UInt32

  init(
    deviceID: AudioDeviceID,
    uid: String,
    name: String,
    isSystemDefault: Bool,
    transportType: UInt32 = 0
  ) {
    self.deviceID = deviceID
    self.uid = uid
    self.name = name
    self.isSystemDefault = isSystemDefault
    self.transportType = transportType
  }

  var id: String {
    uid
  }

  var isVirtual: Bool {
    transportType == kAudioDeviceTransportTypeVirtual
      || name.localizedCaseInsensitiveContains("ZoomAudioDevice")
      || name.localizedCaseInsensitiveContains("Microsoft Teams Audio")
  }
}

// MARK: - MacAudioInputDeviceManager

enum MacAudioInputDeviceManager {
  static func availableInputDevices() -> [MacAudioInputDevice] {
    let defaultDeviceID = defaultInputDeviceID()
    return (try? allDeviceIDs())?
      .filter(hasInputStreams)
      .compactMap { deviceID in
        guard let uid = stringProperty(
          kAudioDevicePropertyDeviceUID,
          objectID: deviceID
        ), let name = stringProperty(
          kAudioObjectPropertyName,
          objectID: deviceID
        ) else {
          return nil
        }
        return MacAudioInputDevice(
          deviceID: deviceID,
          uid: uid,
          name: name,
          isSystemDefault: deviceID == defaultDeviceID,
          transportType: uint32Property(
            kAudioDevicePropertyTransportType,
            objectID: deviceID
          ) ?? 0
        )
      }
      .sorted { lhs, rhs in
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      } ?? []
  }

  static func configureInput(
    of engine: AVAudioEngine,
    preferredDeviceUID: String
  ) throws -> MacAudioInputDevice {
    let devices = availableInputDevices()
    let candidates = inputDeviceCandidates(
      preferredDeviceUID: preferredDeviceUID,
      devices: devices
    )
    guard !candidates.isEmpty else {
      throw MacAudioInputDeviceError.deviceUnavailable
    }
    guard let audioUnit = engine.inputNode.audioUnit else {
      throw MacAudioInputDeviceError.configurationFailed
    }

    for candidate in candidates {
      if configureInput(of: engine, audioUnit: audioUnit, device: candidate) {
        return candidate
      }
    }
    throw MacAudioInputDeviceError.configurationFailed
  }

  static func activeAutomaticInputDevice() async throws -> MacAudioInputDevice {
    let candidates = inputDeviceCandidates(
      preferredDeviceUID: "",
      devices: availableInputDevices()
    )
    guard !candidates.isEmpty else {
      throw MacAudioInputDeviceError.deviceUnavailable
    }

    var firstConfigurableDevice: MacAudioInputDevice?
    for candidate in candidates {
      switch await probeInputSignal(from: candidate) {
      case .active:
        return candidate
      case .silent:
        firstConfigurableDevice = firstConfigurableDevice ?? candidate
      case .unavailable:
        continue
      }
    }

    // A very quiet room or hardware noise gate may make every probe look silent.
    // Keep the system-default behavior in that case rather than refusing to record.
    guard let firstConfigurableDevice else {
      throw MacAudioInputDeviceError.configurationFailed
    }
    return firstConfigurableDevice
  }

  static func automaticInputDevice(
    from devices: [MacAudioInputDevice]? = nil
  ) -> MacAudioInputDevice? {
    inputDeviceCandidates(
      preferredDeviceUID: "",
      devices: devices ?? availableInputDevices()
    ).first
  }

  static func inputDeviceCandidates(
    preferredDeviceUID: String,
    devices: [MacAudioInputDevice]
  ) -> [MacAudioInputDevice] {
    let physicalDevices = devices.filter { !$0.isVirtual }
    let automaticDevices = physicalDevices.isEmpty ? devices : physicalDevices
    var candidates: [MacAudioInputDevice] = []
    if let preferredDevice = devices.first(where: { $0.uid == preferredDeviceUID }) {
      candidates.append(preferredDevice)
    }
    if let systemDefault = automaticDevices.first(where: \.isSystemDefault),
       !candidates.contains(systemDefault) {
      candidates.append(systemDefault)
    }
    candidates.append(contentsOf: automaticDevices.filter { !candidates.contains($0) })
    return candidates
  }

  static func isUsableInputSignal(peakAmplitude: Float) -> Bool {
    peakAmplitude > 0.000_01
  }

  private static func configureInput(
    of engine: AVAudioEngine,
    audioUnit: AudioUnit,
    device: MacAudioInputDevice
  ) -> Bool {
    var deviceID = device.deviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    let format = engine.inputNode.outputFormat(forBus: 0)
    return status == noErr && format.sampleRate > 0 && format.channelCount > 0
  }

  private static func probeInputSignal(
    from device: MacAudioInputDevice
  ) async -> MacAudioInputProbeResult {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    guard let audioUnit = inputNode.audioUnit,
          configureInput(of: engine, audioUnit: audioUnit, device: device)
    else {
      return .unavailable
    }

    let inputFormat = inputNode.outputFormat(forBus: 0)
    let probe = MacAudioInputSignalProbe()
    inputNode.installTap(
      onBus: 0,
      bufferSize: 512,
      format: inputFormat
    ) { buffer, _ in
      probe.consume(buffer)
    }

    do {
      engine.prepare()
      try engine.start()
      try? await Task.sleep(for: .milliseconds(450))
      inputNode.removeTap(onBus: 0)
      engine.stop()
      engine.reset()
      return isUsableInputSignal(peakAmplitude: probe.peakAmplitude) ? .active : .silent
    } catch {
      inputNode.removeTap(onBus: 0)
      engine.stop()
      engine.reset()
      return .unavailable
    }
  }

  private static func allDeviceIDs() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize
    ) == noErr else {
      throw MacAudioInputDeviceError.enumerationFailed
    }

    var deviceIDs = Array(
      repeating: AudioDeviceID(kAudioObjectUnknown),
      count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    )
    let status = deviceIDs.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return kAudio_ParamError
      }
      return AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        baseAddress
      )
    }
    guard status == noErr else {
      throw MacAudioInputDeviceError.enumerationFailed
    }
    return deviceIDs
  }

  private static func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize,
      &deviceID
    )
    return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
  }

  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    return AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &dataSize
    ) == noErr && dataSize > 0
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &dataSize,
        pointer
      )
    }
    guard status == noErr else {
      return nil
    }
    return value.map { $0 as String }
  }

  private static func uint32Property(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID
  ) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      objectID,
      &address,
      0,
      nil,
      &dataSize,
      &value
    )
    return status == noErr ? value : nil
  }
}

// MARK: - MacAudioInputProbeResult

private enum MacAudioInputProbeResult {
  case active
  case silent
  case unavailable
}

// MARK: - MacAudioInputSignalProbe

private final class MacAudioInputSignalProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedPeakAmplitude: Float = 0

  var peakAmplitude: Float {
    lock.withLock { storedPeakAmplitude }
  }

  func consume(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameCount > 0, channelCount > 0 else { return }

    var bufferPeak: Float = 0
    for channelIndex in 0 ..< channelCount {
      for sample in UnsafeBufferPointer(
        start: channels[channelIndex],
        count: frameCount
      ) {
        bufferPeak = max(bufferPeak, abs(sample))
      }
    }
    lock.withLock {
      storedPeakAmplitude = max(storedPeakAmplitude, bufferPeak)
    }
  }
}

// MARK: - MacAudioInputDeviceError

enum MacAudioInputDeviceError: LocalizedError {
  case enumerationFailed
  case deviceUnavailable
  case configurationFailed

  var errorDescription: String? {
    switch self {
    case .enumerationFailed:
      "Jingo could not read the available microphone devices."

    case .deviceUnavailable:
      "Jingo could not find an available microphone."

    case .configurationFailed:
      "Jingo could not start any available microphone."
    }
  }
}
