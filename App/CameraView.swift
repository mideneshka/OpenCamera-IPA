// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation
import PhotosUI

final class PreviewSurface:UIView {
    override class var layerClass:AnyClass {AVCaptureVideoPreviewLayer.self}
    var preview:AVCaptureVideoPreviewLayer {layer as! AVCaptureVideoPreviewLayer}
    private let focusRing=CAShapeLayer()
    private var focusGeneration=0
    override init(frame:CGRect) {
        super.init(frame:frame)
        focusRing.strokeColor=UIColor.systemYellow.cgColor
        focusRing.fillColor=UIColor.clear.cgColor
        focusRing.lineWidth=2
        focusRing.isHidden=true
        layer.addSublayer(focusRing)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func showFocus(at point:CGPoint) {
        focusGeneration+=1
        let generation=focusGeneration
        focusRing.path=UIBezierPath(rect:CGRect(x:point.x-32,y:point.y-32,width:64,height:64)).cgPath
        focusRing.isHidden=false
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { [weak self] in
            guard let self,self.focusGeneration==generation else {return}
            self.focusRing.isHidden=true
        }
    }
}
struct CameraPreview:UIViewRepresentable {
    let camera:CameraService
    func makeUIView(context:Context)->PreviewSurface {
        let view=PreviewSurface(); view.preview.session=camera.session; view.preview.videoGravity = .resizeAspect
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap); return view
    }
    func updateUIView(_ view:PreviewSurface,context:Context) {
        if let connection=view.preview.connection,connection.isVideoOrientationSupported {connection.videoOrientation = .portrait}
    }
    func makeCoordinator()->Coordinator {Coordinator(camera)}
    final class Coordinator:NSObject {
        let camera:CameraService
        init(_ camera:CameraService) {self.camera=camera}
        @objc func tap(_ gesture:UITapGestureRecognizer) {
            guard let view=gesture.view as? PreviewSurface else {return}
            let location=gesture.location(in:view)
            // Ignore letterboxing: focus only within the actual camera image.
            let point=view.preview.captureDevicePointConverted(fromLayerPoint:location)
            guard (0...1).contains(point.x),(0...1).contains(point.y),
                  !camera.busy,!camera.recording else {return}
            camera.focus(point)
            view.showFocus(at:location)
        }
    }
}
struct CameraView:View {
    @StateObject private var camera=CameraService()
    @Environment(\.scenePhase) private var phase
    @AppStorage("capture.mode") private var modeName=CaptureMode.photo.rawValue
    @AppStorage("capture.frames") private var frames=3
    @AppStorage("capture.hdrRange") private var hdrRange=0
    @AppStorage("capture.timer") private var timer=0
    @AppStorage("capture.grid") private var grid=true
    @AppStorage("post.denoise") private var denoise=0.0
    @AppStorage("post.dehaze") private var dehaze=0.0
    @AppStorage("post.contrast") private var contrast=0.0
    @AppStorage("post.saturation") private var saturation=1.0
    @AppStorage("post.temperature") private var temperature=0.0
    @AppStorage("post.sharpen") private var sharpen=0.0
    @State private var zoom=1.0
    @State private var iso=100.0
    @State private var shutterLog = -2.0
    @State private var manual=false
    @State private var bias=0.0
    @State private var focus=0.5
    @State private var kelvin=5000.0
    @State private var flash=false
    @State private var showSettings=false
    @State private var imported:PhotosPickerItem?
    @State private var countdown=0
    @State private var timerTask:Task<Void,Never>?
    var mode:CaptureMode {CaptureMode(rawValue:modeName) ?? .photo}
    var options:ProcessingOptions {ProcessingOptions(denoise:Float(denoise),dehaze:Float(dehaze),contrast:Float(contrast),saturation:Float(saturation),temperature:Float(temperature),sharpen:Float(sharpen))}
    var body:some View {
        VStack(spacing:10) {
            HStack {
                Text("HyabridCam").font(.headline)
                Spacer()
                Button {showSettings=true} label:{Image(systemName:"slider.horizontal.3")}.accessibilityLabel("Настройки")
            }.padding(.horizontal)
            ZStack {
                CameraPreview(camera:camera)
                if grid {GridOverlay().allowsHitTesting(false)}
                if countdown>0 {Text("\(countdown)").font(.system(size:64,weight:.bold)).shadow(radius:4)}
            }.background(.black)
            Text(camera.status).font(.caption).multilineTextAlignment(.center).padding(.horizontal)
            Picker("Объектив",selection:Binding(get:{camera.selectedLens},set:{camera.selectLens($0); zoom=1})) {
                ForEach(camera.lenses){Text($0.name).tag($0.id)}
            }.disabled(camera.busy || camera.recording || countdown>0)
            HStack {Text(String(format:"%.1f×",zoom)); Slider(value:$zoom,in:1...max(1.01,camera.zoomMax)).onChange(of:zoom){camera.zoom($0)}}.padding(.horizontal)
            Picker("Режим",selection:$modeName) {
                ForEach(CaptureMode.allCases){Text($0.rawValue).tag($0.rawValue)}
            }.pickerStyle(.segmented).disabled(camera.busy || camera.recording || countdown>0).padding(.horizontal)
            HStack(spacing:32) {
                PhotosPicker(selection:$imported,matching:.images) {Image(systemName:"photo.on.rectangle").font(.title2)}
                    .disabled(camera.busy || camera.recording || countdown>0)
                Button(action:shutter) {
                    Image(systemName:camera.recording ? "stop.circle.fill":"circle.inset.filled")
                        .font(.system(size:64)).foregroundStyle(camera.recording ? .red:.white)
                }.disabled(camera.busy || countdown>0 || (mode == .raw && !camera.rawSupported))
                    .accessibilityLabel(camera.recording ? "Остановить видео":"Снять")
                if camera.busy || countdown>0 {
                    Button("Отмена") {timerTask?.cancel(); countdown=0; camera.cancel()}
                } else {Button {flash.toggle()} label:{Image(systemName:flash ? "bolt.fill":"bolt.slash")}}
            }.padding(.bottom)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented:$showSettings){settings}
        .task {camera.start()}
        .onChange(of:phase){value in
            if value == .active {camera.start()} else {timerTask?.cancel(); countdown=0; camera.stop()}
        }
        .onChange(of:imported){item in
            guard let item else {return}
            Task {
                do {
                    guard let data=try await item.loadTransferable(type:Data.self) else {return}
                    camera.edit(data:data,options:options)
                } catch {camera.status=error.localizedDescription}
                imported=nil
            }
        }
    }
    private func shutter() {
        if camera.recording {camera.stopVideo(); return}
        let selectedMode=mode, selectedFrames=frames, selectedOptions=options, selectedFlash=flash
        timerTask=Task { @MainActor in
            for n in stride(from:timer,to:0,by:-1) {
                countdown=n
                do {try await Task.sleep(nanoseconds:1_000_000_000)} catch {countdown=0; return}
            }
            countdown=0
            guard !Task.isCancelled else {return}
            camera.capture(mode:selectedMode,frames:selectedFrames,hdrRange:Float(hdrRange),options:selectedOptions,flash:selectedFlash)
        }
    }
    private var settings:some View {
        NavigationStack {
            Form {
                Section("Съёмка") {
                    Picker("Кадров NR/HDR",selection:$frames){ForEach([3,5,7],id:\.self){Text("\($0)").tag($0)}}
                    Picker("HDR: диапазон",selection:$hdrRange) {
                        Text("Авто").tag(0)
                        ForEach([2,3,4],id:\.self){Text("±\($0) EV").tag($0)}
                    }
                    Text("Выравнивание яркости HDR: 3/5/7 кадров. Держи телефон неподвижно до окончания серии.").font(.caption)
                    Picker("Таймер",selection:$timer){ForEach([0,3,5,10],id:\.self){Text("\($0) с").tag($0)}}
                    Toggle("Сетка",isOn:$grid)
                    Text(camera.rawSupported ? "RAW доступен для текущего объектива":"RAW не объявлен текущим объективом").font(.caption)
                    Text("HDR учитывает выдержку и ISO исходных JPEG и сжимает диапазон светов и теней. Диапазон EV ограничивается камерой. Охват сохраняется.").font(.caption)
                }
                Section("Экспозиция и фокус") {
                    Toggle("Ручные ISO и выдержка",isOn:$manual).onChange(of:manual){value in if value {applyExposure()} else {camera.autoExposure()}}
                    if manual {
                        Text("ISO \(Int(iso))")
                        Slider(value:$iso,in:camera.isoRange).onChange(of:iso){_ in applyExposure()}
                        Text(String(format:"Выдержка %.4f с",pow(10,shutterLog)))
                        Slider(value:$shutterLog,in:log10(camera.exposureRange.lowerBound)...log10(camera.exposureRange.upperBound))
                            .onChange(of:shutterLog){_ in applyExposure()}
                    } else {
                        Text(String(format:"Коррекция %.1f EV",bias))
                        Slider(value:$bias,in:-2...2).onChange(of:bias){camera.bias(Float($0))}
                    }
                    Text("Ручной фокус")
                    Slider(value:$focus,in:0...1).onChange(of:focus){camera.focusDistance(Float($0))}
                    Text("WB \(Int(kelvin)) K")
                    Slider(value:$kelvin,in:2500...9000).onChange(of:kelvin){camera.whiteBalance(Float($0))}
                    Text("Для автофокуса коснись предпросмотра.").font(.caption)
                }
                Section("Обработка NR/HDR и импортированных фото") {
                    setting("NLM",value:$denoise,range:0...16)
                    setting("Дымка",value:$dehaze,range:0...1)
                    setting("Контраст",value:$contrast,range:0...1)
                    setting("Насыщенность",value:$saturation,range:0...2)
                    setting("Температура",value:$temperature,range:-1...1)
                    setting("Резкость",value:$sharpen,range:0...1)
                    Button("Нейтральная обработка") {denoise=0; dehaze=0; contrast=0; saturation=1; temperature=0; sharpen=0}
                    Text("Обработка локальная. NLM пока работает на CPU и может быть медленным. RAW SR и RealESRGAN отложены.").font(.caption)
                }
            }.disabled(camera.busy || camera.recording)
            .navigationTitle("HyabridCam")
            .toolbar {ToolbarItem(placement:.confirmationAction){Button("Готово"){showSettings=false}}}
        }
    }
    private func applyExposure() {camera.manual(iso:iso,seconds:pow(10,shutterLog))}
    private func setting(_ title:String,value:Binding<Double>,range:ClosedRange<Double>)->some View {
        VStack(alignment:.leading){Text(String(format:"%@ %.2f",title,value.wrappedValue)); Slider(value:value,in:range)}
    }
}
struct GridOverlay:View {
    var body:some View {
        GeometryReader {g in
            Path {p in
                for i in 1...2 {
                    let x=g.size.width*CGFloat(i)/3, y=g.size.height*CGFloat(i)/3
                    p.move(to:CGPoint(x:x,y:0)); p.addLine(to:CGPoint(x:x,y:g.size.height))
                    p.move(to:CGPoint(x:0,y:y)); p.addLine(to:CGPoint(x:g.size.width,y:y))
                }
            }.stroke(.white.opacity(0.35),lineWidth:0.5)
        }
    }
}
