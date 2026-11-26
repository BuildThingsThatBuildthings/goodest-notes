import XCTest
import PencilKit
import AVFoundation
import ImageIO
@testable import Blockbook

final class TeachingMotionTests:XCTestCase {
    @MainActor func testOriginalCircuitRoundTripAndCaptionedMovie() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let studio=Studio(folder:folder)
        let id=try await CircuitLesson.add(to:studio)
        XCTAssertTrue(studio.flushWrites())
        let paper=try XCTUnwrap(studio.paper(id)),page=try XCTUnwrap(paper.pages.first),visual=try XCTUnwrap(page.visual)
        let original=try studio.drawing(page.id).dataRepresentation()
        let file=studio.assetFolder.appendingPathComponent(visual.filename)
        let gif=try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL,nil))
        XCTAssertEqual(CGImageSourceGetCount(gif),40)
        func frame(_ index:Int)throws->Data {try XCTUnwrap(UIImage(cgImage:XCTUnwrap(CGImageSourceCreateImageAtIndex(gif,index,nil))).pngData())}
        XCTAssertEqual(try frame(0),try frame(39))
        XCTAssertNotEqual(try frame(0),try frame(26))
        let attachment=XCTAttachment(contentsOfFile:file);attachment.name="circuit-demo.gif";attachment.lifetime = .keepAlways;add(attachment)
        let box=visual.rect
        let corners=[box.origin,CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY),CGPoint(x:box.minX,y:box.maxY)]
        let selected=try XCTUnwrap(SketchSelection(polygon:corners,studio:studio,paper:paper,page:page))
        let scene=SketchScene(selected,group:[0],motion:.hinge,amount:30,wire:1,bulb:2)
        let movie=folder.appendingPathComponent("circuit.mp4")
        try await NarratedSketch.render(scene:scene,caption:CircuitLesson.narration,to:movie)
        let asset=AVURLAsset(url:movie)
        let video=try await asset.loadTracks(withMediaType:.video),sound=try await asset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(video.count,1);XCTAssertEqual(sound.count,1)
        let movieAttachment=XCTAttachment(contentsOfFile:movie);movieAttachment.name="circuit-demo.mp4";movieAttachment.lifetime = .keepAlways;add(movieAttachment)
        XCTAssertEqual(original,try Studio(folder:folder).drawing(page.id).dataRepresentation())
    }
}
