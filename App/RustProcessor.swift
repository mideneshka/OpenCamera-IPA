// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import CoreImage
import ImageIO

struct ProcessingOptions {
    var denoise: Float = 0
    var dehaze: Float = 0
    var contrast: Float = 0
    var saturation: Float = 1
    var temperature: Float = 0
    var sharpen: Float = 0
}

enum CameraFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Own on the capture worker. cancel() alone may be called from the main thread.
final class RustProcessor {
    private let handle: OpaquePointer
    private let cancelToken: OpaquePointer?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let ci = CIContext(options: [.cacheIntermediates: false])
    deinit { hc_destroy(handle) }
    init() { let context=hc_create()!; handle=context; cancelToken=hc_cancel_token(context) }
    func cancel() { hc_cancel(cancelToken) }
    private func check(_ code: Int32) throws {
        guard code == 0 else {
            throw CameraFailure.message([1:"Разный размер кадров или более 13 Мп", 2:"Неверные параметры",
                3:"Недостаточно памяти", 4:"Обработка отменена", 5:"Нет кадров", 6:"Ошибка Rust-ядра"][code] ?? "Ошибка ядра \(code)")
        }
    }
    func run(_ frames: [Data], mode: UInt32, options: ProcessingOptions) throws -> Data {
        try check(hc_reset(handle))
        var dimensions: (Int,Int)?
        for data in frames {
            try autoreleasepool {
                guard let input = CIImage(data: data, options: [.applyOrientationProperty:true]) else {
                    throw CameraFailure.message("Не удалось декодировать снимок")
                }
                guard input.extent.width*input.extent.height <= 13_000_000 else {
                    throw CameraFailure.message("Для обработки выбери разрешение до 13 Мп")
                }
                guard let cg = ci.createCGImage(input, from:input.extent, format:.RGBA8, colorSpace:colorSpace) else {
                    throw CameraFailure.message("Не удалось декодировать снимок")
                }
                let w=cg.width, h=cg.height
                guard w*h <= 13_000_000 else { throw CameraFailure.message("Для обработки выбери разрешение до 13 Мп") }
                if let d=dimensions, d != (w,h) { throw CameraFailure.message("Кадры серии имеют разный размер") }
                dimensions=(w,h)
                var pixels=[UInt8](repeating:0,count:w*h*4)
                let code: Int32 = try pixels.withUnsafeMutableBytes { bytes in
                    guard let context=CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,
                        bytesPerRow:w*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                        throw CameraFailure.message("Не удалось выделить буфер")
                    }
                    context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
                    // CGContext produces premultiplied alpha; unpremultiply for the Rust contract.
                    let p=bytes.bindMemory(to:UInt8.self)
                    for i in stride(from:0,to:p.count,by:4) {
                        let a=Int(p[i+3]); if a>0 && a<255 {
                            for c in 0..<3 { p[i+c]=UInt8(min(255,(Int(p[i+c])*255+a/2)/a)) }
                        }
                    }
                    return hc_add_rgba(handle,UInt32(w),UInt32(h),p.baseAddress,p.count)
                }
                try check(code)
                if mode == 2 { try addExposure(data) }
            }
        }
        guard let (w,h)=dimensions else { throw CameraFailure.message("Нет кадров") }
        var adjustments=hc_adjustments(denoise:options.denoise,dehaze:options.dehaze,contrast:options.contrast,
            saturation:options.saturation,temperature:options.temperature,sharpen:options.sharpen)
        try check(hc_run(handle,mode,12,&adjustments))
        var output=Data(count:w*h*4)
        try output.withUnsafeMutableBytes { bytes in
            try check(hc_copy_output(handle,bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count))
        }
        guard let provider=CGDataProvider(data:output as CFData),
              let cg=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                space:colorSpace,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
              let result=UIImage(cgImage:cg).pngData() else { throw CameraFailure.message("Не удалось записать PNG") }
        return result
    }
    private func addExposure(_ data:Data) throws {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil) else { throw metadataError() }
        guard let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else { throw metadataError() }
        guard let exif=properties[kCGImagePropertyExifDictionary as String] as? [String:Any] else { throw metadataError() }
        guard let time=exif[kCGImagePropertyExifExposureTime as String] as? NSNumber else { throw metadataError() }
        guard let speeds=exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let iso=speeds.first else { throw metadataError() }
        let exposure:Float=time.floatValue * iso.floatValue
        try check(hc_set_exposure(handle,exposure))
    }
    private func metadataError()->CameraFailure {
        .message("Нет данных экспозиции: HDR отменён, исходники сохранены")
    }

}
