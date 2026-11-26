import XCTest
import PencilKit
import PDFKit
@testable import Blockbook

@MainActor private final class DisplayProbe: NSObject {
    var samples:[Double]=[]
    private var timestamp:Double?
    var advance:()->Void={}
    @objc func frame(_ link:CADisplayLink){
        if let timestamp {samples.append(link.timestamp-timestamp)}
        timestamp=link.timestamp
        advance()
    }
}
final class ClassroomRenderingTests:XCTestCase {
    @MainActor func testPopulatedBoardAndPDFDuringTeachingPlayback() async throws {
        let fm=FileManager.default,folder=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? fm.removeItem(at:folder)}
        let studio=Studio(folder:folder)
        let base=try await CircuitLesson.add(to:studio)
        let example=try XCTUnwrap(studio.paper(base)?.pages.first), visual=try XCTUnwrap(example.visual)
        let strokes=CircuitLesson.drawing()
        let batch=(0..<50).flatMap { i in strokes.transformed(using:CGAffineTransform(translationX:CGFloat(i%10)*560,y:CGFloat(i/10)*250)).strokes }
        let objects=(0..<40).map { i in CanvasItem(kind:.text,title:"Station \(i)",frame:CGRect(x:i%10*540,y:i/10*260,width:180,height:50)) }
        var page=SheetPage();page.canvas=CanvasContent(items:objects,connections:[])
        let board=BoardSurface(page:page,drawing:PKDrawing(strokes:batch))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.frame=scene.coordinateSpace.bounds
        let host=UIViewController();window.rootViewController=host;window.isHidden=false
        defer {window.isHidden=true}
        board.frame=host.view.bounds;host.view.addSubview(board);board.layoutIfNeeded()
        board.showVisual(visual,folder:studio.assetFolder);board.configure(.pan,color:.black,width:3)
        let probe=DisplayProbe(),link=CADisplayLink(target:probe,selector:#selector(DisplayProbe.frame(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:60,preferred:60)
        board.scrollViewWillBeginDragging(board)
        var x:CGFloat=0
        probe.advance={ x+=1;board.moveViewport(by:CGPoint(x:x.truncatingRemainder(dividingBy:48)<24 ? 2 : -2,y:0)) }
        link.add(to:.main,forMode:.common)
        try await Task.sleep(for:.seconds(2));link.invalidate();board.scrollViewDidEndDragging(board,willDecelerate:false)
        let intervals=Array(probe.samples.dropFirst(5)).sorted();XCTAssertGreaterThan(intervals.count,10)
        if !intervals.isEmpty {
            let median=intervals[intervals.count/2],p95=intervals[min(intervals.count-1,intervals.count*95/100)]
            let line=String(format:"500 strokes, 40 canvas items, GIF playback: display-link median %.2f ms, p95 %.2f ms, mean %.1f fps (%d intervals).",median*1000,p95*1000,Double(intervals.count)/intervals.reduce(0,+),intervals.count)
            print(line);let report=XCTAttachment(string:line);report.lifetime = .keepAlways;add(report)
        }
        let bounds=CGRect(x:0,y:0,width:612,height:792),file=folder.appendingPathComponent("fixture.pdf")
        try UIGraphicsPDFRenderer(bounds:bounds).writePDF(to:file){ctx in ctx.beginPage();("Physics" as NSString).draw(at:CGPoint(x:40,y:40),withAttributes:nil)}
        let pdfID=try await studio.importPDF(file),paper=try XCTUnwrap(studio.paper(pdfID)),pdfPage=try XCTUnwrap(paper.pages.first)
        let sheet=SheetSurface(page:pdfPage,kind:.pdf,pdf:studio.pdf(pdfID)?.page(at:0),drawing:PKDrawing())
        board.removeFromSuperview();sheet.frame=host.view.bounds;host.view.addSubview(sheet);sheet.layoutIfNeeded()
        sheet.changed={studio.saveInk($0,paperID:pdfID,pageID:pdfPage.id)}
        sheet.showVisual(visual,folder:studio.assetFolder);sheet.applyMagnifiedDrawing(strokes)
        XCTAssertTrue(studio.editPage(pdfID,pdfPage.id){$0.typed="Agent result"})
        sheet.showVisual(nil,folder:studio.assetFolder);XCTAssertTrue(studio.flushWrites())
        let reopened=Studio(folder:folder)
        XCTAssertEqual(try reopened.drawing(pdfPage.id).strokes.count,strokes.strokes.count)
        XCTAssertEqual(reopened.paper(pdfID)?.pages.first?.typed,"Agent result")
        XCTAssertEqual(try Data(contentsOf:file),try Data(contentsOf:reopened.url(pdfID,"pdf")))
    }
}
