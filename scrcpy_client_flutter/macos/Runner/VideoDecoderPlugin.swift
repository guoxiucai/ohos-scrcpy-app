import Cocoa
import FlutterMacOS
import VideoToolbox
import CoreVideo
import CoreGraphics
import ImageIO

/// MethodChannel "scrcpy/decoder"
/// - codec=0: H264 Annex-B → VTDecompressionSession → CVPixelBuffer
/// - codec=1: RAW RGBA → 直接拷成 CVPixelBuffer 上屏
/// - codec=2: JPEG → CGImageSource 解码 → CVPixelBuffer 上屏
class VideoDecoderPlugin: NSObject, FlutterTexture, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
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
      if codec == 0 {
        decode(annexB: [UInt8](nal))
      } else if codec == 1 {
        feedRaw(nal)
      } else if codec == 2 {
        feedJpeg(nal)
      }
      result(nil)
    case "dispose":
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
