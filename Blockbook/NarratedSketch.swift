import AVFoundation
import UIKit

enum NarratedSketch {
    @MainActor private static func speak(_ text:String,to url:URL) async throws {
        let capture=SpeechCapture(url:url)
        try await capture.write(text)
    }
    static func render(scene:SketchScene,caption:String,to url:URL) async throws {
        let words=caption.split(whereSeparator:\.isWhitespace)
        guard !words.isEmpty, words.count<=160 else { throw WorkspaceError.message("Use a narration of 1 to 160 words.") }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let composition=AVMutableComposition()
        guard let voice=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw WorkspaceError.message("Could not create the voice track.") }
        var cursor=CMTime.zero, cues:[(end:Double,text:String)]=[]
        var phrases:[String]=[],building:[Substring]=[]
        for word in words {
            building.append(word)
            if building.count>=11 || word.last.map({".!?,;".contains($0)})==true { phrases.append(building.joined(separator:" "));building=[] }
        }
        if !building.isEmpty {phrases.append(building.joined(separator:" "))}
        for (start,phrase) in phrases.enumerated() {
            var file=folder.appendingPathComponent("phrase-\(start).caf")
            if caption==CircuitLesson.narration,let bundled=Bundle.main.url(forResource:"circuit-"+String(start),withExtension:"wav") {file=bundled}
            else {
                do {try await speak(phrase,to:file)}
                catch {
                    let answer=try await WorkspaceConnection.request("/v1/narration",["phrase":phrase]) as? [String:Any]
                    guard let encoded=answer?["data"] as? String,let bytes=Data(base64Encoded:encoded) else {throw WorkspaceError.message("The workspace speech engine returned no audio.")}
                    file=folder.appendingPathComponent("phrase-\(start).wav")
                    try bytes.write(to:file,options:.atomic)
                }
            }
            let asset=AVURLAsset(url:file),duration=try await asset.load(.duration)
            guard let track=try await asset.loadTracks(withMediaType:.audio).first, duration.seconds>0 else {throw WorkspaceError.message("System speech produced an empty phrase.")}
            try voice.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:track,at:cursor)
            cursor=cursor+duration;cues.append((cursor.seconds,phrase))
        }
        let film=folder.appendingPathComponent("ink.mp4"), length=max(3.2,cursor.seconds+0.4)
        try await frames(scene:scene,length:length,cues:cues,stagedCircuit:caption==CircuitLesson.narration,to:film)
        let asset=AVURLAsset(url:film)
        guard let source=try await asset.loadTracks(withMediaType:.video).first,
              let picture=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw WorkspaceError.message("Could not assemble the movie.")}
        try picture.insertTimeRange(CMTimeRange(start:.zero,duration:try await asset.load(.duration)),of:source,at:.zero)
        guard let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality) else {throw WorkspaceError.message("Could not create video export.")}
        export.outputURL=url;export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {throw export.error ?? WorkspaceError.message("Movie export failed.")}
    }
    private static func frames(scene:SketchScene,length:Double,cues:[(end:Double,text:String)],stagedCircuit:Bool,to url:URL) async throws {
        let w=640,h=496,fps=24
        let writer=try AVAssetWriter(url:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:w,AVVideoHeightKey:h])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h])
        writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? WorkspaceError.message("Video encoder unavailable.")}
        writer.startSession(atSourceTime:.zero)
        let format=UIGraphicsImageRendererFormat();format.opaque=true;format.scale=1
        let renderer=UIGraphicsImageRenderer(size:CGSize(width:w,height:h),format:format)
        for index in 0..<Int(ceil(length*Double(fps))) {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {throw writer.error ?? WorkspaceError.message("Encoder interrupted.")}
                try await Task.sleep(for:.milliseconds(5))
            }
            let ok=autoreleasepool { () -> Bool in
                let t=Double(index)/Double(fps), ratio=min(608/scene.size.width,382/scene.size.height)
                let image=renderer.image { c in
                    UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:w,height:h))
                    let size=CGSize(width:scene.size.width*ratio,height:scene.size.height*ratio)
                    let progress:Double
                    if stagedCircuit,cues.count==4 {
                        let stage=cues.firstIndex(where:{ t<$0.end }) ?? 3
                        let begin=stage==0 ? 0:cues[stage-1].end
                        let fraction=min(1,max(0,(t-begin)/max(0.01,cues[stage].end-begin)))
                        let stops=[0.0,0.39,0.48,0.62,0.75]
                        progress=stops[stage]+fraction*(stops[stage+1]-stops[stage])
                    }else{progress=min(0.75,t/length)}
                    scene.frame(progress).draw(in:CGRect(x:(640-size.width)/2,y:(410-size.height)/2,width:size.width,height:size.height))
                    let p=NSMutableParagraphStyle();p.alignment = .center
                    let line=cues.first { t<$0.end }?.text ?? ""
                    (line as NSString).draw(in:CGRect(x:30,y:414,width:580,height:76),withAttributes:[.font:UIFont.systemFont(ofSize:22,weight:.medium),.foregroundColor:UIColor.black,.paragraphStyle:p])
                }
                var pixel:CVPixelBuffer?
                guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)==kCVReturnSuccess,let pixel,let cg=image.cgImage else {return false}
                CVPixelBufferLockBaseAddress(pixel,[]);defer {CVPixelBufferUnlockBaseAddress(pixel,[])}
                let flags=CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue
                guard let ctx=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:w,height:h,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:flags) else {return false}
                ctx.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
                return adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(index),timescale:Int32(fps)))
            }
            guard ok else {throw writer.error ?? WorkspaceError.message("Could not write a movie frame.")}
        }
        input.markAsFinished();await writer.finishWriting()
        guard writer.status == .completed else {throw writer.error ?? WorkspaceError.message("Could not finish the movie.")}
    }
}

@MainActor private final class SpeechCapture: NSObject, AVSpeechSynthesizerDelegate {
    let synth=AVSpeechSynthesizer()
    let url:URL
    let queue=DispatchQueue(label:"goodest-notes.speech-file")
    nonisolated(unsafe) private var audio:AVAudioFile?
    private var completion:CheckedContinuation<Void,Error>?
    private var timeout:Task<Void,Never>?
    init(url:URL){self.url=url;super.init();synth.delegate=self}
    func write(_ text:String) async throws {
        let utterance=AVSpeechUtterance(string:text)
        utterance.voice=AVSpeechSynthesisVoice(language:"en-US")
        utterance.rate=AVSpeechUtteranceDefaultSpeechRate
        try await withCheckedThrowingContinuation { cont in
            completion=cont
            // Some unavailable voices never send a last buffer. Keep the writer
            // alive until a real completion or a bounded, actionable failure.
            timeout=Task { [self] in
                do {try await Task.sleep(for:.seconds(5))} catch{return}
                complete(WorkspaceError.message("System speech did not deliver audio. Check the installed English voice and retry."))
            }
            synth.write(utterance) { [self] buffer in
                guard let pcm=buffer as? AVAudioPCMBuffer else {return}
                queue.sync {
                    do {
                        if pcm.frameLength==0 {audio=nil;Task { @MainActor in self.complete(nil) };return}
                        if audio==nil {audio=try AVAudioFile(forWriting:url,settings:pcm.format.settings,commonFormat:pcm.format.commonFormat,interleaved:pcm.format.isInterleaved)}
                        try audio?.write(from:pcm)
                    } catch {Task { @MainActor in self.complete(error) }}
                }
            }
        }
    }
    private func complete(_ error:Error?){
        guard let completion else{return}
        self.completion=nil;timeout?.cancel();timeout=nil
        queue.sync {audio=nil}
        if let error {synth.stopSpeaking(at:.immediate);completion.resume(throwing:error)}
        else if (try? AVAudioFile(forReading:url).length) ?? 0 > 0 {completion.resume()}
        else {completion.resume(throwing:WorkspaceError.message("System speech produced no audio."))}
    }
}
