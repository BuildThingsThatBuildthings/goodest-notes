import XCTest
import PDFKit
import PencilKit
@testable import Blockbook

final class BlockbookTests: XCTestCase {
    func testLiveReuseAndVariationPreserveOrderAndOverrides() throws {
        var base = Block(title: "Prepare workshop")
        base[.outcome] = "Deliver a workshop"; base[.now] = "Nothing"; base[.tools] = "Projector"
        var a = Workflow(title: "First class"), b = Workflow(title: "Second class")
        a.steps = [Placement(blockID: base.id)]
        b.steps = [Placement(blockID: base.id), Placement(blockID: base.id)]
        var lib = Library(workflows: [a,b], blocks: [base])
        var v = Block(title: "Remote workshop", parentID: base.id)
        v[.tools] = ""
        lib.save(v, in: b.id, replacing: b.steps[0].id)
        base[.outcome] = "Deliver two workshops"
        lib.save(base)
        let restored = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(lib))
        XCTAssertEqual(restored.resolved(v)[.outcome], "Deliver two workshops")
        XCTAssertEqual(restored.resolved(v)[.tools], "")
        XCTAssertEqual(restored.resolved(v)[.now], "Nothing")
        XCTAssertEqual(restored.workflows[0].steps[0].blockID, base.id)
        XCTAssertEqual(restored.workflows[1].steps.map(\.blockID), [v.id,base.id])
        XCTAssertEqual(restored.workflows[1].steps[0].id, b.steps[0].id)
        v.values.removeValue(forKey: BlockField.tools.rawValue)
        XCTAssertEqual(lib.resolved(v)[.tools], "Projector")
    }

    func testConversionFilesAndGraphReferences() throws {
        var b = Block(title: "Claude Demo / Workshop")
        b[.process] = "Collect slides\nCheck the projector"
        b[.now] = "Nothing"; b[.tech] = "Projector"; b[.evidence] = "All slides are readable"
        let v = Block(title: "Afternoon", parentID: b.id)
        let w = Workflow(title: "Two sessions", steps: [Placement(blockID: b.id), Placement(blockID: v.id), Placement(blockID: b.id)])
        let lib = Library(workflows: [w], blocks: [b,v])
        let converter = Conversion(lib, workflow: w)
        let graph = try JSONDecoder().decode(Conversion.Graph.self, from: Data(contentsOf: converter.write(.graph)))
        let nodes = Set(graph.nodes.map(\.id))
        XCTAssertTrue(graph.edges.allSatisfy { nodes.contains($0.from) && nodes.contains($0.to) })
        XCTAssertEqual(graph.edges.filter { $0.relation == "uses" }.compactMap(\.position), [1,2,3])
        XCTAssertEqual(graph.nodes.filter { $0.label == "Projector" }.count, 1)
        XCTAssertTrue(graph.edges.contains { $0.relation == "variationOf" && $0.from == v.id.uuidString })
        XCTAssertTrue(try String(contentsOf: converter.write(.markdown)).contains("## 2. Afternoon"))
        let folder = try Conversion(lib,block: b).write(.skill)
        let skill = try String(contentsOf: folder.appendingPathComponent("SKILL.md"))
        XCTAssertTrue(skill.contains("name: \(folder.lastPathComponent)\n")); XCTAssertFalse(folder.lastPathComponent.contains("claude"))
        XCTAssertTrue(skill.contains("### Verify effectiveness\n\nAll slides are readable"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.md").path))
    }

    @MainActor func testSavedDrawingAndPDFRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Studio(folder: folder)
        let input = folder.appendingPathComponent("Fixture.pdf")
        let rect = CGRect(x: 0,y: 0,width: 512,height: 400)
        try UIGraphicsPDFRenderer(bounds: rect).writePDF(to: input) { out in
            out.beginPage()
            ("A searchable passage" as NSString).draw(at: CGPoint(x: 25,y: 50), withAttributes: [.font:UIFont.systemFont(ofSize: 23)])
            out.beginPage()
            UIColor.blue.setFill(); out.fill(CGRect(x: 20,y: 20,width: 60,height: 60))
        }
        let id = try await store.importPDF(input)
        let paper = try XCTUnwrap(store.paper(id)); XCTAssertEqual(paper.pages.count,2)
        XCTAssertTrue(SearchHit.search("searchable", in: store.library).contains { $0.route == .paper(id,paper.pages[0].id) })
        let points = [CGPoint(x: 80,y: 140),CGPoint(x: 210,y: 140)].enumerated().map { index,p in
            PKStrokePoint(location:p,timeOffset: Double(index)*0.1,size:CGSize(width:12,height:12),opacity:1,force:1,azimuth:0,altitude:.pi/2)
        }
        let ink = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.red),path:PKStrokePath(controlPoints:points,creationDate:Date()))])
        store.saveInk(ink, paperID:id, pageID:paper.pages[0].id)
        XCTAssertTrue(store.flushWrites())
        let again = Studio(folder:folder)
        XCTAssertEqual(try again.drawing(paper.pages[0].id).strokes.count,1)
        let output = try SheetRenderer.export(paper, from:again)
        let pdf = try XCTUnwrap(PDFDocument(url:output))
        XCTAssertEqual(pdf.pageCount,2)
        XCTAssertTrue(pdf.page(at:0)?.string?.contains("searchable") == true)
        let original = try XCTUnwrap(PDFDocument(url:input))
        XCTAssertNotEqual(pdf.page(at:0)?.thumbnail(of: rect.size, for:.cropBox).pngData(),original.page(at:0)?.thumbnail(of: rect.size, for:.cropBox).pngData())
        XCTAssertNil(again.issue)
    }

    func testCapturedLabelsMapToReusableFields() {
        let text = "Outcome: Teach the class\nEvidence: Students complete the exercise\nNow: Nothing\nProcess: Open the deck\nRun the demo\nTides: New licensing rules"
        let fields = CaptureAnalysis.labeledFields(text)
        XCTAssertEqual(fields["outcome"], "Teach the class")
        XCTAssertEqual(fields["now"], "Nothing")
        XCTAssertEqual(fields["process"], "Open the deck\nRun the demo")
        XCTAssertEqual(fields["tides"], "New licensing rules")
        XCTAssertNil(fields["cost"])
    }

    @MainActor func testDamagedManifestIsPreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let path = folder.appendingPathComponent("library.json"), bad = Data([0xff])
        try bad.write(to:path)
        let store = Studio(folder:folder)
        XCTAssertNotNil(store.issue); XCTAssertFalse(store.change { $0.blocks.append(Block(title:"New")) })
        XCTAssertEqual(try Data(contentsOf:path),bad)
    }
}
