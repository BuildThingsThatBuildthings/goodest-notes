import SwiftUI
import PencilKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct TeachingVisual: Codable, Equatable, Identifiable {
    var id = UUID()
    var rect: CGRect
    var caption: String
    var filename: String
}
struct SketchSelection: Identifiable {
    let id = UUID()
    let rect: CGRect
    let strokes: [PKStroke]
    let background: UIImage
    @MainActor init?(polygon: [CGPoint], studio: Studio, paper: Paper, page: SheetPage) throws {
        guard let first = polygon.first, polygon.count >= 3 else { return nil }
        let path = UIBezierPath(); path.move(to:first)
        polygon.dropFirst().forEach { path.addLine(to:$0) }; path.close()
        let ink = try studio.drawing(page.id)
        let selected = ink.strokes.map { stroke in
            let points = stroke.path.interpolatedPoints(by:.distance(max(4,stroke.renderBounds.width/48))).prefix(200)
            let samples = points.map { path.contains($0.location.applying(stroke.transform)) }
            return !samples.isEmpty && samples.filter { $0 }.count * 2 >= samples.count
        }
        strokes = zip(ink.strokes,selected).compactMap { $1 ? $0 : nil }
        guard !strokes.isEmpty else { return nil }
        let box = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let margin=max(12,min(64,max(box.width,box.height)*0.18))
        let area = box.insetBy(dx:-margin,dy:-margin)
        rect=area
        let rest=PKDrawing(strokes:zip(ink.strokes,selected).compactMap { $1 ? nil : $0 })
        let pdf=page.pdfIndex.flatMap { studio.pdf(paper.id)?.page(at:$0) }
        background=SheetRenderer.image(rect:area) { ctx in
            SheetRenderer.background(ctx,page:page,kind:paper.kind,pdf:pdf)
            SheetRenderer.paintItems(studio,page:page,in:area,context:ctx)
            if rest.bounds.intersects(area) { rest.image(from:area,scale:min(2,512/max(area.width,area.height))).draw(in:area) }
        }
    }
}
enum StrokeMotion: String, CaseIterable { case hinge = "Rotate on hinge", travel = "Move along path" }
struct SketchScene {
    let stationary: UIImage, moving: UIImage
    let size: CGSize, pivot: CGPoint
    let motion: StrokeMotion
    let amount: Double
    let signal: [CGPoint]
    let filament: [CGPoint]
    init(_ source: SketchSelection, group: Set<Int>, motion: StrokeMotion, amount: Double, wire:Int?=nil, bulb:Int?=nil, pivotAtEnd:Bool=false) {
        let rect=source.rect, scale=min(512/max(rect.width,rect.height),3)
        size=CGSize(width:max(2,ceil(rect.width*scale/2)*2),height:max(2,ceil(rect.height*scale/2)*2))
        self.motion=motion; self.amount=amount
        let active=source.strokes.enumerated().filter { group.contains($0.offset) }.map(\.element)
        let still=source.strokes.enumerated().filter { !group.contains($0.offset) }.map(\.element)
        let format=UIGraphicsImageRendererFormat(); format.scale=1
        let target=CGRect(origin:.zero,size:size)
        stationary=UIGraphicsImageRenderer(size:target.size,format:format).image { _ in
            source.background.draw(in:target)
            if !still.isEmpty { PKDrawing(strokes:still).image(from:rect,scale:scale).draw(in:target) }
        }
        moving=PKDrawing(strokes:active).image(from:rect,scale:scale)
        let first=active.first
        let anchor=(pivotAtEnd ? first?.path.last : first?.path.first).map { $0.location.applying(first!.transform) } ?? CGPoint(x:rect.midX,y:rect.midY)
        pivot=CGPoint(x:(anchor.x-rect.minX)*target.width/rect.width,y:(anchor.y-rect.minY)*target.height/rect.height)
        func trace(_ index:Int?)->[CGPoint] {
            guard let index,source.strokes.indices.contains(index) else {return []}
            let stroke=source.strokes[index]
            return stroke.path.interpolatedPoints(by:.distance(max(1,max(rect.width,rect.height)/160))).prefix(1024).map { sample in
                let p=sample.location.applying(stroke.transform)
                return CGPoint(x:(p.x-rect.minX)*target.width/rect.width,y:(p.y-rect.minY)*target.height/rect.height)
            }
        }
        signal=trace(wire);filament=trace(bulb)
    }
    func frame(_ progress: Double) -> UIImage {
        let format=UIGraphicsImageRendererFormat(); format.scale=1; format.opaque=true
        return UIGraphicsImageRenderer(size:size,format:format).image { output in
            let rect=CGRect(origin:.zero,size:size), ctx=output.cgContext
            stationary.draw(in:rect)
            let t = progress < 0.15 ? 0 : progress < 0.48 ? (progress-0.15)/0.33 : progress < 0.76 ? 1 : min(1,max(0,(1-progress)/0.24))
            let eased=t*t*(3-2*t)
            ctx.saveGState()
            if motion == .hinge { ctx.translateBy(x:pivot.x,y:pivot.y);ctx.rotate(by:amount * .pi/180 * eased);ctx.translateBy(x:-pivot.x,y:-pivot.y) }
            else { ctx.translateBy(x:size.width * amount/180 * eased,y:0) }
            moving.draw(in:rect);ctx.restoreGState()
            let accent=UIColor(red:0.96,green:0.53,blue:0.12,alpha:1)
            if progress>=0.48 && progress<0.62 && !signal.isEmpty {
                let i=min(signal.count-1,Int((progress-0.48)/0.14*Double(signal.count)))
                let point=signal[i];ctx.setFillColor(accent.cgColor);ctx.fillEllipse(in:CGRect(x:point.x-4,y:point.y-4,width:8,height:8))
            }
            if progress>=0.62 && progress<=0.76, let first=filament.first {
                ctx.setStrokeColor(accent.cgColor);ctx.setShadow(offset:.zero,blur:7,color:accent.cgColor);ctx.setLineCap(.round);ctx.setLineJoin(.round);ctx.setLineWidth(4)
                ctx.move(to:first);filament.dropFirst().forEach { ctx.addLine(to:$0) };ctx.strokePath()
            }
        }
    }
    func gif(to url: URL) throws {
        let count=40
        guard let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.gif.identifier as CFString,count,nil) else { throw WorkspaceError.message("Could not create the GIF.") }
        CGImageDestinationSetProperties(dest,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for index in 0..<count { autoreleasepool { if let cg=frame(Double(index)/Double(count-1)).cgImage { CGImageDestinationAddImage(dest,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.08]] as CFDictionary) } } }
        guard CGImageDestinationFinalize(dest) else { throw WorkspaceError.message("Could not save the GIF.") }
    }
}

final class VisualPlayback: UIView {
    private var identity: UUID?
    private let imageView=UIImageView()
    private let movie=AVPlayerLayer()
    private var observer: NSObjectProtocol?
    private var world = CGRect.zero
    func place(_ convert: (CGPoint)->CGPoint) {
        let a=convert(world.origin), b=convert(CGPoint(x:world.maxX,y:world.maxY))
        frame=CGRect(x:a.x,y:a.y,width:max(0,b.x-a.x),height:max(0,b.y-a.y))
    }
    override init(frame:CGRect) { super.init(frame:frame); isUserInteractionEnabled=false; addSubview(imageView);layer.addSublayer(movie);movie.videoGravity = .resizeAspect; clipsToBounds=true }
    required init?(coder:NSCoder){ fatalError() }
    override func layoutSubviews(){super.layoutSubviews();imageView.frame=bounds;CATransaction.begin();CATransaction.setDisableActions(true);movie.frame=bounds;CATransaction.commit()}
    func configure(_ visual: TeachingVisual?, folder: URL){
        if identity == visual?.id { return }
        identity=visual?.id;imageView.stopAnimating();imageView.animationImages=nil;imageView.image=nil;movie.player?.pause();movie.player=nil
        if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
        isHidden=visual == nil
        guard let visual, !visual.filename.contains("/") else { return }
        world=visual.rect
        let url=folder.appendingPathComponent(visual.filename)
        if url.pathExtension=="mp4" {
            let player=AVPlayer(url:url);movie.player=player
            observer=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:player.currentItem,queue:.main){ [weak player] _ in player?.seek(to:.zero);player?.play() };player.play()
        } else if let src=CGImageSourceCreateWithURL(url as CFURL,nil) {
            let count=CGImageSourceGetCount(src)
            if count<=1 { imageView.image=UIImage(contentsOfFile:url.path);return }
            var duration=0.0
            imageView.animationImages=(0..<min(count,80)).compactMap { index in
                let props=CGImageSourceCopyPropertiesAtIndex(src,index,nil) as? [CFString:Any]
                let gif=props?[kCGImagePropertyGIFDictionary] as? [CFString:Any]
                duration += gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                return CGImageSourceCreateImageAtIndex(src,index,nil).map { UIImage(cgImage:$0) }
            };imageView.animationDuration=duration;imageView.startAnimating()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

struct SketchStudio: View {
    let source: SketchSelection
    let folder: URL
    var save: (TeachingVisual)->Void
    @Environment(\.dismiss) var dismiss
    @State private var caption=""
    @State private var motion=StrokeMotion.hinge
    @State private var group=Set([0])
    @State private var amount=24.0
    @State private var wire:Int?
    @State private var bulb:Int?
    @State private var pivotAtEnd=false
    @State private var progress=0.0
    @State private var status=""
    @State private var busy=false
    @State private var remoteRequest: [String:String]=[:]
    @State private var providerGIF: Bool?
    var scene: SketchScene { SketchScene(source,group:group,motion:motion,amount:amount,wire:wire,bulb:bulb,pivotAtEnd:pivotAtEnd) }
    func perform(_ mode:String) async {
        busy=true; defer { busy=false }
        do {
            let scene=self.scene, directory=folder
            let suffix=mode=="image" ? "png" : mode=="video" ? "mp4" : "gif"
            let filename=UUID().uuidString+"."+suffix, url=directory.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if ["analyze","image","gif"].contains(mode) {
                var prompt=caption.isEmpty ? "Identify what happens in this drawing." : caption
                if mode=="analyze" {
                    let positions=source.strokes.prefix(36).enumerated().compactMap { i,s -> String? in
                        guard let a=s.path.first?.location.applying(s.transform),let b=s.path.last?.location.applying(s.transform) else {return nil}
                        let xy: (CGPoint)->String={ p in "\(Int((p.x-source.rect.minX)/source.rect.width*100)),\(Int((p.y-source.rect.minY)/source.rect.height*100))" }
                        return "\(i):\(xy(a))->\(xy(b))"
                    }
                    prompt=String(prompt.prefix(1200))+" Stroke IDs with start/end in percent: "+positions.joined(separator:" ")
                }
                let signature=mode+"."+prompt
                let id=remoteRequest[signature] ?? UUID().uuidString;remoteRequest[signature]=id
                guard let reference=scene.frame(0).pngData() else { throw WorkspaceError.message("Unable to encode the drawing.") }
                let result=try await WorkspaceConnection.request("/v1/visual",["request_id":id,"reference":reference.base64EncodedString(),"prompt":prompt,"mode":mode]) as? [String:Any]
                if mode=="analyze",let explanation=result?["text"] as? String { caption=explanation
                    if let plan=result?["plan"] as? [String:Any] {
                        let ids=(plan["moving"] as? [Int] ?? []).filter { source.strokes.indices.contains($0) }
                        if !ids.isEmpty {group=Set(ids)}
                        motion=plan["motion"] as? String=="travel" ? .travel:.hinge
                        amount=min(75,max(-75,plan["amount"] as? Double ?? amount))
                        pivotAtEnd=plan["pivotAtEnd"] as? Bool ?? false
                        wire=(plan["wire"] as? Int).flatMap { source.strokes.indices.contains($0) ? $0:nil }
                        bulb=(plan["filament"] as? Int).flatMap { source.strokes.indices.contains($0) ? $0:nil }
                    }
                    return }
                guard let encoded=result?["data"] as? String,let bytes=Data(base64Encoded:encoded) else { throw WorkspaceError.message("The image provider returned no media.") }
                try bytes.write(to:url,options:.atomic)
            } else if mode=="video" {
                try await NarratedSketch.render(scene:scene,caption:caption,to:url)
            } else { try await Task.detached(priority:.userInitiated) { try scene.gif(to:url) }.value }
            save(TeachingVisual(rect:source.rect,caption:caption,filename:filename));dismiss()
        } catch { status=error.localizedDescription }
    }
    var body: some View {
        NavigationStack { Form {
            Section {
                Image(uiImage:scene.frame(progress)).resizable().scaledToFit().frame(maxHeight:190).frame(maxWidth:.infinity)
                Slider(value:$progress,in:0...1) { Text("Inspect animation frames") }
            }
            Section("What happens in this drawing?") {
                TextField("Describe the action and result",text:$caption,axis:.vertical)
                Button("Analyze drawing with AI") { Task { await perform("analyze") } }
            }
            Section("Original ink motion") {
                Picker("Movement",selection:$motion) { ForEach(StrokeMotion.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Menu("Moving strokes · \(group.count) selected") {
                    ForEach(0..<source.strokes.count,id:\.self) { index in Button("Stroke \(index+1)",systemImage:group.contains(index) ? "checkmark.circle.fill":"circle") {
                        if group.contains(index) { if group.count>1 {group.remove(index)} } else {group.insert(index)}
                    } }
                }
                if motion == .hinge { Toggle("Hinge at stroke end",isOn:$pivotAtEnd) }
                Picker("Signal path",selection:$wire) { Text("None").tag(Int?.none);ForEach(0..<source.strokes.count,id:\.self) { Text("Stroke \($0+1)").tag(Optional($0)) } }
                Picker("Light after contact",selection:$bulb) { Text("None").tag(Int?.none);ForEach(0..<source.strokes.count,id:\.self) { Text("Stroke \($0+1)").tag(Optional($0)) } }
                Slider(value:$amount,in:-75...75,step:1) { Text("Travel or rotation") }
                Text(motion == .hinge ? "Rotate \(Int(amount))° around the first point of the moving stroke." : "Move the selected ink horizontally.").font(.caption)
            }
            Section("Add to page") {
                Button("Animate my drawing") { Task { await perform("ink") } }
                Button("Generate image with OpenAI") { Task { await perform("image") } }
                Button("Create GIF with OpenAI") { Task { await perform("gif") } }.disabled(providerGIF == false)
                if providerGIF == false { Text("The workspace has no verified GIF-capable image model.").font(.caption) }
                Button("Create locally rendered ink GIF") { Task { await perform("local") } }
                Button("Make narrated video") { Task { await perform("video") } }.disabled(caption.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if !status.isEmpty { Text(status) }
            }
        }.disabled(busy).overlay { if busy { ProgressView("Preparing visual…").padding().background(.regularMaterial,in:Capsule()) } }
        .navigationTitle("Drawing studio").toolbar { Button("Close") { dismiss() }.disabled(busy) }
        .task {
            if let result=try? await WorkspaceConnection.request("/v1/providers") as? [String:[String:Any]] { providerGIF=(result["openai"]?["models"] as? [String] ?? []).contains("gpt-image-2.6-flare") }
        } }
    }
}
