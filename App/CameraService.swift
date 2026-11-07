// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Photos
import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo="Фото", raw="RAW", noise="NR", hdr="HDR", video="Видео"
    var id: String { rawValue }
}
struct LensChoice: Identifiable { let id:String; let name:String }

/// All AVFoundation configuration and capture sequencing run on worker.
final class CameraService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    let session=AVCaptureSession()
    private let worker=DispatchQueue(label:"app.hyabridcam.capture",qos:.userInitiated)
    private let photos=AVCapturePhotoOutput()
    private let movie=AVCaptureMovieFileOutput()
    private let processor=RustProcessor()
    private var device:AVCaptureDevice?
    private var devices:[AVCaptureDevice]=[]
    private var input:AVCaptureDeviceInput?
    private var configured=false
    private var taking=false
    private var sequence:[Data]=[]
    private var rawFiles:[Data]=[]
    private var remaining=0
    private var index=0
    private var total=1
    private var captureMode=CaptureMode.photo
    private var captureOptions=ProcessingOptions()
    private var baseBias:Float=0
    private var wasFocus:AVCaptureDevice.FocusMode?
    private var wasWB:AVCaptureDevice.WhiteBalanceMode?
    private var wasExposure:AVCaptureDevice.ExposureMode?
    private var wasISO:Float=100
    private var wasDuration:CMTime = .zero
    private var archive:URL?
    private var cancelled=false
    private var audioAllowed=false
    @Published var lenses:[LensChoice]=[]
    @Published var selectedLens=""
    @Published var rawSupported=false
    @Published var busy=false
    @Published var recording=false
    @Published var status="Ожидание разрешения камеры"
    @Published var zoomMax:Double=1
    @Published var isoRange: ClosedRange<Double> = 25...1600
    @Published var exposureRange: ClosedRange<Double> = 0.0001...1

    private func publish(_ block:@escaping ()->Void) { DispatchQueue.main.async(execute:block) }
    private func fail(_ error:Error) { publish {self.status=error.localizedDescription} }
    func start() {
        Task {
            let camera=await AVCaptureDevice.requestAccess(for:.video)
            guard camera else { publish {self.status="Разреши доступ к камере в Настройках"}; return }
            audioAllowed=await AVCaptureDevice.requestAccess(for:.audio)
            worker.async {
                do {
                    if !self.configured { try self.configure() }
                    self.session.startRunning()
                } catch { self.fail(error) }
            }
        }
    }
    func stop() { worker.async { if !self.movie.isRecording {self.session.stopRunning()} } }
    private func configure() throws {
        session.beginConfiguration(); defer {session.commitConfiguration()}
        session.sessionPreset = .photo
        devices=AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera],
            mediaType:.video,position:.unspecified).devices
        guard let first=devices.first(where:{$0.position == .back}) ?? devices.first else {throw CameraFailure.message("Камеры не найдены")}
        try install(first)
        guard session.canAddOutput(photos) else {throw CameraFailure.message("Фото недоступно")}
        session.addOutput(photos); photos.maxPhotoQualityPrioritization = .quality
        if audioAllowed {
            let mic=AVCaptureDevice.default(for:.audio)
            if let mic, let audio=try? AVCaptureDeviceInput(device:mic), session.canAddInput(audio) {session.addInput(audio)}
        }
        configured=true
        publish {
            self.lenses=self.devices.map{LensChoice(id:$0.uniqueID,name:$0.localizedName+($0.position == .front ? " · фронтальная":""))}
            self.status="Камера готова"; self.selectedLens=first.uniqueID
        }
        worker.async {self.updateCapabilities()}
    }
    private func install(_ new:AVCaptureDevice) throws {
        let replacement=try AVCaptureDeviceInput(device:new)
        let old=input
        if let old {session.removeInput(old)}
        guard session.canAddInput(replacement) else {
            if let old,session.canAddInput(old) {session.addInput(old)}
            throw CameraFailure.message("Не удалось переключить объектив")
        }
        session.addInput(replacement); input=replacement; device=new
    }
    private func updateCapabilities() {
        guard let d=device else {return}
        let raw = !photos.availableRawPhotoPixelFormatTypes.isEmpty
        let maxZoom=Double(min(d.activeFormat.videoMaxZoomFactor,10))
        let lo=Double(d.activeFormat.minISO), hi=Double(d.activeFormat.maxISO)
        let minT=max(0.000001,CMTimeGetSeconds(d.activeFormat.minExposureDuration))
        let maxT=CMTimeGetSeconds(d.activeFormat.maxExposureDuration)
        publish {self.rawSupported=raw; self.zoomMax=maxZoom; self.isoRange=lo...hi; self.exposureRange=minT...maxT}
    }
    func selectLens(_ id:String) {
        worker.async {
            guard !self.taking,!self.movie.isRecording,let d=self.devices.first(where:{$0.uniqueID==id}) else {return}
            self.session.beginConfiguration()
            do {try self.install(d); self.session.commitConfiguration(); self.updateCapabilities(); self.publish{self.selectedLens=id}}
            catch {self.session.commitConfiguration(); self.fail(error)}
        }
    }
    func zoom(_ value:Double) { control {d in d.videoZoomFactor=CGFloat(value).clamped(to:1...min(d.activeFormat.videoMaxZoomFactor,10))} }
    func bias(_ value:Float) {control {d in d.setExposureTargetBias(value.clamped(to:d.minExposureTargetBias...d.maxExposureTargetBias),completionHandler:nil)}}
    func manual(iso:Double,seconds:Double) {
        control {d in
            guard d.isExposureModeSupported(.custom) else {return}
            let t=seconds.clamped(to:CMTimeGetSeconds(d.activeFormat.minExposureDuration)...CMTimeGetSeconds(d.activeFormat.maxExposureDuration))
            d.setExposureModeCustom(duration:CMTime(seconds:t,preferredTimescale:1_000_000_000),
                iso:Float(iso).clamped(to:d.activeFormat.minISO...d.activeFormat.maxISO),completionHandler:nil)
        }
    }
    func autoExposure() {control {d in if d.isExposureModeSupported(.continuousAutoExposure) {d.exposureMode = .continuousAutoExposure}}}
    func focus(_ point:CGPoint) {
        control {d in
            if d.isFocusPointOfInterestSupported {d.focusPointOfInterest=point}
            if d.isFocusModeSupported(.autoFocus) {d.focusMode = .autoFocus}
            if d.isExposurePointOfInterestSupported {d.exposurePointOfInterest=point}
        }
    }
    func focusDistance(_ value:Float) {control {d in if d.isLockingFocusWithCustomLensPositionSupported {d.setFocusModeLocked(lensPosition:value.clamped(to:0...1),completionHandler:nil)}}}
    func whiteBalance(_ kelvin:Float) {
        control {d in
            guard d.isWhiteBalanceModeSupported(.locked) else {return}
            var gains=d.deviceWhiteBalanceGains(for:AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature:kelvin,tint:0))
            gains.redGain=gains.redGain.clamped(to:1...d.maxWhiteBalanceGain)
            gains.greenGain=gains.greenGain.clamped(to:1...d.maxWhiteBalanceGain)
            gains.blueGain=gains.blueGain.clamped(to:1...d.maxWhiteBalanceGain)
            d.setWhiteBalanceModeLocked(with:gains,completionHandler:nil)
        }
    }
    private func control(_ action:@escaping (AVCaptureDevice)->Void) {
        worker.async {guard !self.taking,let d=self.device else {return}; do {try d.lockForConfiguration(); defer {d.unlockForConfiguration()}; action(d)} catch {self.fail(error)}}
    }
    func capture(mode:CaptureMode,frames:Int,options:ProcessingOptions,flash:Bool) {
        worker.async {
            guard self.configured,!self.taking,!self.movie.isRecording else {return}
            if mode == .video {self.beginVideo(); return}
            self.taking=true; self.cancelled=false; self.sequence=[]; self.rawFiles=[]
            self.captureMode=mode; self.captureOptions=options
            self.total=(mode == .noise || mode == .hdr) ? ([3,5,7].contains(frames) ? frames:3) : 1
            self.remaining=self.total; self.index=0; self.baseBias=self.device?.exposureTargetBias ?? 0
            do {
                let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                self.archive=documents.appendingPathComponent("Captures/"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:self.archive!,withIntermediateDirectories:true)
                if let d=self.device {try d.lockForConfiguration(); self.wasFocus=d.focusMode; self.wasWB=d.whiteBalanceMode
                    self.wasExposure=d.exposureMode; self.wasISO=d.iso; self.wasDuration=d.exposureDuration
                    if mode == .noise || mode == .hdr {
                        if d.isFocusModeSupported(.locked) {d.focusMode = .locked}
                        if d.isWhiteBalanceModeSupported(.locked) {d.whiteBalanceMode = .locked}
                        if mode == .noise,d.isExposureModeSupported(.locked) {d.exposureMode = .locked}
                    }; d.unlockForConfiguration()}
                self.publish{self.busy=true; self.status="Съёмка"}
                self.nextPhoto(flash:flash)
            } catch {self.finish(error:error)}
        }
    }
    private func nextPhoto(flash:Bool) {
        if cancelled {finish(error:CameraFailure.message("Съёмка отменена")); return}
        let send={
            if self.cancelled {self.finish(error:CameraFailure.message("Съёмка отменена")); return}
            var settings=AVCapturePhotoSettings(format:[AVVideoCodecKey:AVVideoCodecType.jpeg])
            if self.captureMode == .raw {
                guard let format=self.photos.availableRawPhotoPixelFormatTypes.first else {self.finish(error:CameraFailure.message("RAW недоступен для этого объектива")); return}
                settings=AVCapturePhotoSettings(rawPixelFormatType:format,processedFormat:[AVVideoCodecKey:AVVideoCodecType.jpeg])
            }
            if self.total==1,self.captureMode != .raw,self.photos.supportedFlashModes.contains(.on) {settings.flashMode=flash ? .on:.off}
            settings.photoQualityPrioritization = .quality
            if let connection=self.photos.connection(with:.video),connection.isVideoOrientationSupported {connection.videoOrientation = .portrait}
            self.photos.capturePhoto(with:settings,delegate:self)
        }
        if captureMode == .hdr,let d=device {
            do {
                try d.lockForConfiguration()
                if d.isExposureModeSupported(.continuousAutoExposure) {d.exposureMode = .continuousAutoExposure}
                let range:Float=total==3 ? 2:total==5 ? 3:4
                // Reference exposure first, then alternating negative/positive EV.
                let slot=index==0 ? 0:((index+1)/2)*(index%2==1 ? -1:1)
                let ev=baseBias+Float(slot)*range/Float(total/2)
                d.setExposureTargetBias(ev.clamped(to:d.minExposureTargetBias...d.maxExposureTargetBias)) {_ in
                    self.worker.asyncAfter(deadline:.now()+0.15,execute:send)
                }; d.unlockForConfiguration()
            } catch {finish(error:error)}
        } else {send()}
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishProcessingPhoto photo:AVCapturePhoto,error:Error?) {
        worker.async {
            if let error {self.finish(error:error); return}
            guard self.taking,let data=photo.fileDataRepresentation() else {return}
            if let folder=self.archive {
                do {try data.write(to:folder.appendingPathComponent("frame-\(self.index)."+(photo.isRawPhoto ? "dng":"jpg")),options:.atomic)}
                catch {self.finish(error:error); return}
            }
            if photo.isRawPhoto {self.rawFiles.append(data)} else {self.sequence.append(data)}
        }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings,error:Error?) {
        worker.async {
            guard self.taking else {return}
            if let error {self.finish(error:error); return}
            self.remaining-=1; self.index+=1
            self.publish{self.status="Кадр \(self.index)/\(self.total)"}
            if self.remaining>0 {self.nextPhoto(flash:false); return}
            do {
                guard self.sequence.count==self.total else {throw CameraFailure.message("Получена неполная серия")}
                self.restore()
                let result:Data
                if self.captureMode == .noise || self.captureMode == .hdr {
                    self.publish{self.status="Обработка Rust"}
                    result=try self.processor.run(self.sequence,mode:self.captureMode == .noise ? 1:2,options:self.captureOptions)
                } else {result=self.sequence[0]}
                self.savePhoto(result,raw:self.rawFiles)
            } catch {self.finish(error:error)}
        }
    }
    private func restore() {
        guard let d=device,wasExposure != nil else {return}
        do {try d.lockForConfiguration(); defer {d.unlockForConfiguration()}
            d.setExposureTargetBias(baseBias,completionHandler:nil)
            if let f=wasFocus,d.isFocusModeSupported(f) {d.focusMode=f}
            if let wb=wasWB,d.isWhiteBalanceModeSupported(wb) {d.whiteBalanceMode=wb}
            if let e=wasExposure {
                if e == .custom {d.setExposureModeCustom(duration:wasDuration,iso:wasISO,completionHandler:nil)}
                else if d.isExposureModeSupported(e) {d.exposureMode=e}
            }
            wasExposure=nil; wasFocus=nil; wasWB=nil
        } catch {fail(error)}
    }
    private func savePhoto(_ data:Data,raw:[Data]) {
        PHPhotoLibrary.requestAuthorization(for:.addOnly) {permission in
            guard permission == .authorized || permission == .limited else {self.worker.async{self.finish(error:CameraFailure.message("Разреши добавление снимков в Фото"))}; return}
            PHPhotoLibrary.shared().performChanges {
                let r=PHAssetCreationRequest.forAsset(); r.addResource(with:.photo,data:data,options:nil)
                for dng in raw {let options=PHAssetResourceCreationOptions(); options.uniformTypeIdentifier="com.adobe.raw-image"; r.addResource(with:.alternatePhoto,data:dng,options:options)}
            } completionHandler:{ok,error in self.worker.async{self.finish(error:error ?? (ok ? nil:CameraFailure.message("Сохранение не удалось")))}}
        }
    }
    private func finish(error:Error?) {
        restore(); taking=false; sequence=[]; rawFiles=[]; archive=nil
        publish {self.busy=false; self.status=error?.localizedDescription ?? "Сохранено в Фото"}
    }
    func cancel() {processor.cancel(); worker.async {self.cancelled=true}}
    func edit(data:Data,options:ProcessingOptions) {
        worker.async {
            guard !self.taking,!self.movie.isRecording else {return}
            self.taking=true; self.wasExposure=nil; self.wasFocus=nil; self.wasWB=nil
            self.publish{self.busy=true; self.status="Обработка Rust"}
            do {let result=try self.processor.run([data],mode:0,options:options); self.savePhoto(result,raw:[])} catch {self.finish(error:error)}
        }
    }
    private func beginVideo() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if !session.outputs.contains(movie),session.canAddOutput(movie) {session.addOutput(movie)}
        session.commitConfiguration()
        guard session.outputs.contains(movie) else {fail(CameraFailure.message("Видео недоступно")); return}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        if let connection=movie.connection(with:.video),connection.isVideoOrientationSupported {connection.videoOrientation = .portrait}
        movie.startRecording(to:url,recordingDelegate:self)
        publish{self.recording=true; self.status=self.audioAllowed ? "Запись видео":"Видео без звука: нет доступа к микрофону"}
    }
    func stopVideo() {worker.async{if self.movie.isRecording {self.movie.stopRecording()}}}
    func fileOutput(_ output:AVCaptureFileOutput,didFinishRecordingTo url:URL,from connections:[AVCaptureConnection],error:Error?) {
        worker.async {
            self.session.beginConfiguration(); self.session.removeOutput(self.movie); self.session.sessionPreset = .photo; self.session.commitConfiguration()
            self.updateCapabilities()
            if let error {try? FileManager.default.removeItem(at:url); self.publish{self.recording=false}; self.fail(error); return}
            PHPhotoLibrary.requestAuthorization(for:.addOnly) {permission in
                guard permission == .authorized || permission == .limited else {self.publish{self.recording=false; self.status="Нет доступа к Фото. Видео: \(url.lastPathComponent)"}; return}
                PHPhotoLibrary.shared().performChanges {_ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:url)} completionHandler:{ok,error in
                    if ok {try? FileManager.default.removeItem(at:url)}
                    self.publish{self.recording=false; self.status=error?.localizedDescription ?? (ok ? "Видео сохранено":"Видео не сохранено")}
                }
            }
        }
    }
}
extension Comparable {func clamped(to range:ClosedRange<Self>)->Self {min(max(self,range.lowerBound),range.upperBound)}}
