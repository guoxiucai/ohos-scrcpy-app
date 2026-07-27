import Cocoa
import AVFoundation
import FlutterMacOS
import VideoToolbox
import CoreVideo
import CoreGraphics
import ImageIO
import CoreServices

/// MethodChannel "scrcpy/decoder"
/// - codec=0: H264 Annex-B → VTDecompressionSession → CVPixelBuffer
/// - codec=1: RAW RGBA → 直接拷成 CVPixelBuffer 上屏
/// - codec=2: JPEG → CGImageSource 解码 → CVPixelBuffer 上屏
class VideoDecoderPlugin: NSObject, FlutterTexture, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private var channel: FlutterMethodChannel?
  private lazy var recorder = H264Mp4Recorder { [weak self] state, error in
    DispatchQueue.main.async {
      var arguments: [String: Any] = ["state": state]
      if let message = error {
        arguments["error"] = message
      }
      self?.channel?.invokeMethod("recordingState", arguments: arguments)
    }
  }
  private var textureId: Int64 = -1
  private var session: VTDecompressionSession?
  private var formatDesc: CMVideoFormatDescription?
  private let lock = NSLock()
  private var latestPixelBuffer: CVPixelBuffer?
  private var codec: Int = 0
  private var rawPool: CVPixelBufferPool?
  private var rawWidth: Int = 0
  private var rawHeight: Int = 0
  private var rawFrameCount: Int = 0

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = VideoDecoderPlugin(registrar: registrar)
    let channel = FlutterMethodChannel(name: "scrcpy/decoder",
                                        binaryMessenger: registrar.messenger)
    plugin.channel = channel
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  // MARK: - MethodChannel
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "ARG", message: "missing args", details: nil)); return
      }
      let codec = (args["codec"] as? Int) ?? 0
      self.codec = codec
      teardown()
      do {
        if codec == 0 {
          let sps = (args["sps"] as? FlutterStandardTypedData)?.data ?? Data()
          let pps = (args["pps"] as? FlutterStandardTypedData)?.data ?? Data()
          guard !sps.isEmpty, !pps.isEmpty else {
            result(FlutterError(code: "ARG", message: "missing sps/pps for h264", details: nil))
            return
          }
          try setupH264Session(sps: [UInt8](sps), pps: [UInt8](pps))
        } else if codec == 1 {
          // RAW RGBA: dimensions already known from init args.
          rawWidth = (args["width"] as? Int) ?? 0
          rawHeight = (args["height"] as? Int) ?? 0
        } else if codec == 2 {
          // JPEG: decoded with ImageIO, pool created lazily.
          rawWidth = 0
          rawHeight = 0
        } else {
          result(FlutterError(code: "ARG", message: "unknown codec \(codec)", details: nil))
          return
        }
        if textureId < 0 {
          textureId = registrar.textures.register(self)
        }
        result(textureId)
      } catch {
        result(FlutterError(code: "VTOOL", message: "\(error)", details: nil))
      }
    case "feed":
      guard let args = call.arguments as? [String: Any],
            let nal = (args["nal"] as? FlutterStandardTypedData)?.data else {
        result(nil); return
      }
      let keyframe = (args["keyframe"] as? Bool) ?? false
      let ptsUs = (args["pts"] as? Int64) ?? Int64((args["pts"] as? Int) ?? 0)
      let annexB = Data(nal)
      recorder.feed(annexB: annexB, keyframe: keyframe, ptsUs: ptsUs)
      if codec == 0 {
        decode(annexB: [UInt8](nal))
      } else if codec == 1 {
        feedRaw(nal)
      } else if codec == 2 {
        feedJpeg(nal)
      }
      result(nil)
    case "startRecording":
      guard let args = call.arguments as? [String: Any] else {
        result(mediaResult(ok: false, error: "缺少录制参数")); return
      }
      let width = (args["width"] as? Int) ?? 0
      let height = (args["height"] as? Int) ?? 0
      let fps = (args["fps"] as? Int) ?? 0
      let sps = (args["sps"] as? FlutterStandardTypedData)?.data ?? Data()
      let pps = (args["pps"] as? FlutterStandardTypedData)?.data ?? Data()
      do {
        try recorder.start(width: width, height: height, fps: fps, sps: sps, pps: pps)
        result(mediaResult(ok: true))
      } catch {
        result(mediaResult(ok: false, error: error.localizedDescription))
      }
    case "stopRecording":
      recorder.stop { response in
        DispatchQueue.main.async { result(response) }
      }
    case "cancelRecording":
      recorder.cancel()
      result(mediaResult(ok: true))
    case "capturePng":
      capturePng { response in
        DispatchQueue.main.async { result(response) }
      }
    case "revealInFileManager":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String, !path.isEmpty else {
        result(mediaResult(ok: false, error: "保存路径为空")); return
      }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      result(mediaResult(ok: true, path: path))
    case "dispose":
      recorder.cancel()
      teardown()
      if textureId >= 0 {
        registrar.textures.unregisterTexture(textureId)
        textureId = -1
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capturePng(completion: @escaping ([String: Any]) -> Void) {
    lock.lock()
    let pixelBuffer = latestPixelBuffer
    lock.unlock()
    guard let buffer = pixelBuffer else {
      completion(mediaResult(ok: false, error: "当前没有可截图的解码帧"))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      var image: CGImage?
      let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
      guard status == noErr, let cgImage = image else {
        completion(mediaResult(ok: false, error: "无法读取当前解码帧"))
        return
      }
      do {
        let finalUrl = try MediaFilePath.desktopUrl(prefix: "HongJing_Screenshot", ext: "png")
        let tempUrl = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(
          tempUrl as CFURL, kUTTypePNG, 1, nil) else {
          completion(mediaResult(ok: false, error: "无法创建 PNG 编码器"))
          return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
          try? FileManager.default.removeItem(at: tempUrl)
          completion(mediaResult(ok: false, error: "PNG 编码失败"))
          return
        }
        try FileManager.default.moveItem(at: tempUrl, to: finalUrl)
        completion(mediaResult(ok: true, path: finalUrl.path))
      } catch {
        completion(mediaResult(ok: false, error: error.localizedDescription))
      }
    }
  }

  // MARK: - VideoToolbox H264
  private func setupH264Session(sps: [UInt8], pps: [UInt8]) throws {
    var paramSets: [UnsafePointer<UInt8>] = []
    var paramSetSizes: [Int] = []
    let spsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sps.count)
    spsPtr.initialize(from: sps, count: sps.count)
    let ppsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pps.count)
    ppsPtr.initialize(from: pps, count: pps.count)
    defer {
      spsPtr.deallocate()
      ppsPtr.deallocate()
    }
    paramSets.append(UnsafePointer(spsPtr))
    paramSets.append(UnsafePointer(ppsPtr))
    paramSetSizes.append(sps.count)
    paramSetSizes.append(pps.count)

    var fmt: CMFormatDescription?
    let st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
      allocator: kCFAllocatorDefault,
      parameterSetCount: 2,
      parameterSetPointers: paramSets,
      parameterSetSizes: paramSetSizes,
      nalUnitHeaderLength: 4,
      formatDescriptionOut: &fmt)
    guard st == noErr, let format = fmt else {
      throw NSError(domain: "VTool", code: Int(st))
    }
    formatDesc = format

    let attrs: [NSString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    var session: VTDecompressionSession?
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { (decompressionOutputRefCon, _, status, _, imageBuffer, _, _) in
        guard status == noErr, let buffer = imageBuffer,
              let ctx = decompressionOutputRefCon else { return }
        let me = Unmanaged<VideoDecoderPlugin>.fromOpaque(ctx).takeUnretainedValue()
        me.lock.lock()
        me.latestPixelBuffer = buffer
        me.lock.unlock()
        me.registrar.textures.textureFrameAvailable(me.textureId)
      },
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

    let st2 = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: format,
      decoderSpecification: nil,
      imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &callback,
      decompressionSessionOut: &session)
    guard st2 == noErr, let s = session else {
      throw NSError(domain: "VTool", code: Int(st2))
    }
    self.session = s
  }

  private func teardown() {
    if let s = session {
      VTDecompressionSessionInvalidate(s)
    }
    session = nil
    formatDesc = nil
    rawPool = nil
    rawWidth = 0
    rawHeight = 0
    lock.lock()
    latestPixelBuffer = nil
    lock.unlock()
  }

  private func decode(annexB bytes: [UInt8]) {
    guard let session = session, let format = formatDesc else { return }
    let avcc = annexBToAvcc(bytes)
    if avcc.isEmpty { return }
    var blockBuffer: CMBlockBuffer?
    let dataPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: avcc.count)
    dataPtr.initialize(from: avcc, count: avcc.count)
    let st = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: dataPtr,
      blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: avcc.count,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard st == kCMBlockBufferNoErr, let bb = blockBuffer else {
      dataPtr.deallocate()
      return
    }
    var sampleSizes: [Int] = [avcc.count]
    var sampleBuffer: CMSampleBuffer?
    let st2 = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: bb,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: format,
      sampleCount: 1,
      sampleTimingEntryCount: 0,
      sampleTimingArray: nil,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSizes,
      sampleBufferOut: &sampleBuffer)
    guard st2 == noErr, let sb = sampleBuffer else { return }
    var infoFlags = VTDecodeInfoFlags()
    VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sb,
      flags: [._EnableAsynchronousDecompression],
      frameRefcon: nil,
      infoFlagsOut: &infoFlags)
  }

  private func annexBToAvcc(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    let n = bytes.count
    var i = 0
    while i < n {
      var start = -1
      var hdrLen = 0
      var j = i
      while j + 2 < n {
        if bytes[j] == 0 && bytes[j + 1] == 0 && bytes[j + 2] == 1 {
          start = j; hdrLen = 3; break
        }
        if j + 3 < n && bytes[j] == 0 && bytes[j + 1] == 0 && bytes[j + 2] == 0 && bytes[j + 3] == 1 {
          start = j; hdrLen = 4; break
        }
        j += 1
      }
      if start < 0 { break }
      let nalStart = start + hdrLen
      var end = n
      var k = nalStart
      while k + 2 < n {
        if bytes[k] == 0 && bytes[k + 1] == 0 && bytes[k + 2] == 1 {
          end = k; break
        }
        if k + 3 < n && bytes[k] == 0 && bytes[k + 1] == 0 && bytes[k + 2] == 0 && bytes[k + 3] == 1 {
          end = k; break
        }
        k += 1
      }
      let nalLen = end - nalStart
      if nalLen > 0 {
        let type = bytes[nalStart] & 0x1F
        if type != 7 && type != 8 {
          out.append(UInt8((nalLen >> 24) & 0xFF))
          out.append(UInt8((nalLen >> 16) & 0xFF))
          out.append(UInt8((nalLen >> 8) & 0xFF))
          out.append(UInt8(nalLen & 0xFF))
          out.append(contentsOf: bytes[nalStart..<end])
        }
      }
      i = end
    }
    return out
  }

  // MARK: - RAW RGBA
  private func feedRaw(_ data: Data) {
    guard rawWidth > 0 && rawHeight > 0 else {
      print("[decoder] feedRaw: rawWidth=\(rawWidth) rawHeight=\(rawHeight) not set")
      return
    }
    let pixelBytes = rawWidth * rawHeight * 4
    if data.count < pixelBytes {
      print("[decoder] feedRaw: data.count=\(data.count) < expected=\(pixelBytes)")
      return
    }

    if rawPool == nil {
      let attrs: [NSString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: rawWidth,
        kCVPixelBufferHeightKey: rawHeight,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
      rawPool = pool
      print("[decoder] feedRaw: pool created w=\(rawWidth) h=\(rawHeight)")
    }
    guard let pool = rawPool else { return }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
    guard let pixelBuffer = pb else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let dst = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let srcStride = rawWidth * 4
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let srcPtr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
      let dstPtr = dst.assumingMemoryBound(to: UInt8.self)
      // RGBA -> BGRA (R/B swap)
      for y in 0..<rawHeight {
        let s = srcPtr.advanced(by: y * srcStride)
        let d = dstPtr.advanced(by: y * dstStride)
        var x = 0
        while x < srcStride {
          d[x] = s[x + 2]      // B
          d[x + 1] = s[x + 1]  // G
          d[x + 2] = s[x]      // R
          d[x + 3] = s[x + 3]  // A
          x += 4
        }
      }
    }
    rawFrameCount += 1
    if rawFrameCount <= 3 || rawFrameCount % 30 == 0 {
      print("[decoder] feedRaw: rendered frame #\(rawFrameCount) stride=\(dstStride) expected=\(srcStride)")
    }
    lock.lock()
    latestPixelBuffer = pixelBuffer
    lock.unlock()
    registrar.textures.textureFrameAvailable(textureId)
  }

  // MARK: - JPEG (CGImage)
  private func feedJpeg(_ data: Data) {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
      return
    }
    let w = img.width
    let h = img.height
    if w <= 0 || h <= 0 { return }
    if rawPool == nil || w != rawWidth || h != rawHeight {
      rawWidth = w
      rawHeight = h
      let attrs: [NSString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: w,
        kCVPixelBufferHeightKey: h,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
      rawPool = pool
    }
    guard let pool = rawPool else { return }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
    guard let pixelBuffer = pb else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let dst = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32 =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard let ctx = CGContext(data: dst,
                               width: w,
                               height: h,
                               bitsPerComponent: 8,
                               bytesPerRow: dstStride,
                               space: cs,
                               bitmapInfo: bitmapInfo) else {
      return
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    lock.lock()
    latestPixelBuffer = pixelBuffer
    lock.unlock()
    registrar.textures.textureFrameAvailable(textureId)
  }

  // MARK: - FlutterTexture
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buf = latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(buf)
  }
}

private func mediaResult(
  ok: Bool,
  path: String? = nil,
  error: String? = nil,
  durationUs: Int64 = 0,
  frameCount: Int = 0
) -> [String: Any] {
  var result: [String: Any] = [
    "ok": ok,
    "durationUs": durationUs,
    "frameCount": frameCount,
  ]
  if let path = path { result["path"] = path }
  if let error = error { result["error"] = error }
  return result
}

private enum MediaFilePath {
  static func desktopUrl(prefix: String, ext: String) throws -> URL {
    guard let desktop = FileManager.default.urls(
      for: .desktopDirectory, in: .userDomainMask).first else {
      throw NSError(
        domain: "HongJingMedia",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "无法定位系统桌面目录"])
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let stem = "\(prefix)_\(formatter.string(from: Date()))"
    var candidate = desktop.appendingPathComponent(stem).appendingPathExtension(ext)
    var suffix = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = desktop.appendingPathComponent("\(stem)_\(suffix)")
        .appendingPathExtension(ext)
      suffix += 1
    }
    return candidate
  }
}

private struct PendingRecordFrame {
  let avcc: Data
  let ptsUs: Int64
  let keyframe: Bool
}

/// 将收到的 H.264 压缩访问单元直通封装为 MP4，不进行二次编码。
private final class H264Mp4Recorder {
  typealias StateCallback = (String, String?) -> Void

  private let queue = DispatchQueue(label: "com.hongjing.mp4-recorder")
  private let stateCallback: StateCallback
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var tempUrl: URL?
  private var finalUrl: URL?
  private var active = false
  private var writing = false
  private var pending: PendingRecordFrame?
  private var frameCount = 0
  private var lastFrameUptimeNs: UInt64 = 0
  private var elapsedUs: Int64 = 0

  init(stateCallback: @escaping StateCallback) {
    self.stateCallback = stateCallback
  }

  func start(width: Int, height: Int, fps: Int, sps: Data, pps: Data) throws {
    var startError: Error?
    queue.sync {
      do {
        guard !active else {
          throw NSError(
            domain: "HongJingMedia",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "已有录制任务正在进行"])
        }
        guard width > 0, height > 0, fps > 0, !sps.isEmpty, !pps.isEmpty else {
          throw NSError(
            domain: "HongJingMedia",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "H.264 录制参数不完整"])
        }
        let format = try Self.createFormatDescription(sps: sps, pps: pps)
        let destination = try MediaFilePath.desktopUrl(
          prefix: "HongJing_Recording", ext: "mp4")
        let temporary = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("mp4")
        let assetWriter = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let assetInput = AVAssetWriterInput(
          mediaType: .video,
          outputSettings: nil,
          sourceFormatHint: format)
        assetInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(assetInput) else {
          throw NSError(
            domain: "HongJingMedia",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "系统不支持 H.264 直通封装"])
        }
        assetWriter.add(assetInput)
        writer = assetWriter
        input = assetInput
        tempUrl = temporary
        finalUrl = destination
        active = true
        writing = false
        pending = nil
        frameCount = 0
        lastFrameUptimeNs = 0
        elapsedUs = 0
      } catch {
        startError = error
        reset(removeTemporary: true)
      }
    }
    if let error = startError { throw error }
  }

  func feed(annexB: Data, keyframe: Bool, ptsUs _: Int64) {
    guard !annexB.isEmpty else { return }
    queue.async { [weak self] in
      self?.process(annexB: annexB, keyframe: keyframe)
    }
  }

  func stop(completion: @escaping ([String: Any]) -> Void) {
    queue.async { [weak self] in
      guard let self = self, self.active else {
        completion(mediaResult(ok: false, error: "当前没有录制任务"))
        return
      }
      guard self.writing, let writer = self.writer, let input = self.input,
            let temporary = self.tempUrl, let destination = self.finalUrl else {
        self.reset(removeTemporary: true)
        completion(mediaResult(ok: false, error: "尚未收到有效关键帧"))
        return
      }
      if let frame = self.pending {
        let now = DispatchTime.now().uptimeNanoseconds
        let finalDurationUs = max(
          1, Int64((now - self.lastFrameUptimeNs) / 1_000))
        guard self.append(frame, durationUs: finalDurationUs) else {
          let message = writer.error?.localizedDescription ?? "写入 MP4 失败"
          self.reset(removeTemporary: true)
          completion(mediaResult(ok: false, error: message))
          return
        }
        self.elapsedUs += finalDurationUs
        self.pending = nil
      }
      let duration = max(1, self.elapsedUs)
      let frames = self.frameCount
      writer.endSession(
        atSourceTime: CMTime(value: duration, timescale: 1_000_000))
      input.markAsFinished()
      writer.finishWriting {
        self.queue.async {
          if writer.status == .completed {
            do {
              try FileManager.default.moveItem(at: temporary, to: destination)
              self.reset(removeTemporary: false)
              completion(mediaResult(
                ok: true,
                path: destination.path,
                durationUs: duration,
                frameCount: frames))
            } catch {
              self.reset(removeTemporary: true)
              completion(mediaResult(ok: false, error: error.localizedDescription))
            }
          } else {
            let message = writer.error?.localizedDescription ?? "MP4 文件收尾失败"
            self.reset(removeTemporary: true)
            completion(mediaResult(ok: false, error: message))
          }
        }
      }
    }
  }

  func cancel() {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.writer?.cancelWriting()
      self.reset(removeTemporary: true)
    }
  }

  private func process(annexB: Data, keyframe: Bool) {
    guard active else { return }
    let converted = Self.annexBToAvcc(annexB)
    guard !converted.data.isEmpty else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    if !writing {
      guard keyframe && converted.containsIdr else { return }
      guard let writer = writer, writer.startWriting() else {
        fail(writer?.error?.localizedDescription ?? "无法启动 MP4 写入")
        return
      }
      lastFrameUptimeNs = now
      elapsedUs = 0
      writer.startSession(atSourceTime: .zero)
      writing = true
      stateCallback("recording", nil)
    } else {
      let durationUs = max(
        1, Int64((now - lastFrameUptimeNs) / 1_000))
      if let previous = pending {
        guard append(previous, durationUs: durationUs) else {
          fail(writer?.error?.localizedDescription ?? "写入 MP4 样本失败")
          return
        }
        elapsedUs += durationUs
      }
      lastFrameUptimeNs = now
    }
    pending = PendingRecordFrame(
      avcc: converted.data,
      ptsUs: elapsedUs,
      keyframe: keyframe && converted.containsIdr)
  }

  private func append(_ frame: PendingRecordFrame, durationUs: Int64) -> Bool {
    guard let input = input, input.isReadyForMoreMediaData else { return false }
    var blockBuffer: CMBlockBuffer?
    let createStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: frame.avcc.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: frame.avcc.count,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard createStatus == kCMBlockBufferNoErr, let buffer = blockBuffer else {
      return false
    }
    let copyStatus = frame.avcc.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!,
        blockBuffer: buffer,
        offsetIntoDestination: 0,
        dataLength: frame.avcc.count)
    }
    guard copyStatus == kCMBlockBufferNoErr else { return false }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: durationUs, timescale: 1_000_000),
      presentationTimeStamp: CMTime(value: frame.ptsUs, timescale: 1_000_000),
      decodeTimeStamp: .invalid)
    var sampleSize = frame.avcc.count
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: buffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: input.sourceFormatHint,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer)
    guard sampleStatus == noErr, let sample = sampleBuffer else { return false }
    if !frame.keyframe {
      CMSetAttachment(
        sample,
        key: kCMSampleAttachmentKey_NotSync,
        value: kCFBooleanTrue,
        attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }
    guard input.append(sample) else { return false }
    frameCount += 1
    return true
  }

  private func fail(_ message: String) {
    writer?.cancelWriting()
    reset(removeTemporary: true)
    stateCallback("error", message)
  }

  private func reset(removeTemporary: Bool) {
    if removeTemporary, let temporary = tempUrl {
      try? FileManager.default.removeItem(at: temporary)
    }
    writer = nil
    input = nil
    tempUrl = nil
    finalUrl = nil
    active = false
    writing = false
    pending = nil
    frameCount = 0
    lastFrameUptimeNs = 0
    elapsedUs = 0
  }

  private static func createFormatDescription(sps: Data, pps: Data) throws
    -> CMFormatDescription {
    var format: CMFormatDescription?
    let status: OSStatus = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes in
        let pointers: [UnsafePointer<UInt8>] = [
          spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
          ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
        ]
        let sizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: 2,
          parameterSetPointers: pointers,
          parameterSetSizes: sizes,
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &format)
      }
    }
    guard status == noErr, let description = format else {
      throw NSError(
        domain: "HongJingMedia",
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "无法创建 H.264 格式描述"])
    }
    return description
  }

  private static func annexBToAvcc(_ bytes: Data)
    -> (data: Data, containsIdr: Bool) {
    let source = [UInt8](bytes)
    var output = Data()
    var containsIdr = false
    var index = 0
    while index < source.count {
      guard let start = findStartCode(source, from: index) else { break }
      let nalStart = start.offset + start.length
      let next = findStartCode(source, from: nalStart)
      let nalEnd = next?.offset ?? source.count
      if nalEnd > nalStart {
        let type = source[nalStart] & 0x1F
        if type == 5 { containsIdr = true }
        if type != 7 && type != 8 {
          let length = UInt32(nalEnd - nalStart).bigEndian
          withUnsafeBytes(of: length) { output.append(contentsOf: $0) }
          output.append(contentsOf: source[nalStart..<nalEnd])
        }
      }
      index = nalEnd
    }
    return (output, containsIdr)
  }

  private static func findStartCode(_ bytes: [UInt8], from: Int)
    -> (offset: Int, length: Int)? {
    var index = from
    while index + 2 < bytes.count {
      if bytes[index] == 0 && bytes[index + 1] == 0 {
        if bytes[index + 2] == 1 {
          return (index, 3)
        }
        if index + 3 < bytes.count && bytes[index + 2] == 0 &&
            bytes[index + 3] == 1 {
          return (index, 4)
        }
      }
      index += 1
    }
    return nil
  }
}
