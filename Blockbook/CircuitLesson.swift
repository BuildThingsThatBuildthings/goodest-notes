import PencilKit

enum CircuitLesson {
    static let narration="The switch rotates around its hinge until the contacts meet. Current travels along the wire and lights the filament."
    static func drawing() -> PKDrawing {
        typealias XY=(CGFloat,CGFloat)
        func stroke(_ vertices:[XY])->PKStroke {
            // Subdivide straight sections so PencilKit keeps the wire corners.
            var samples:[CGPoint]=[]
            for (a,b) in zip(vertices,vertices.dropFirst()) {
                let n=max(1,Int(hypot(b.0-a.0,b.1-a.1)/3))
                for i in 0..<n {let t=CGFloat(i)/CGFloat(n);samples.append(CGPoint(x:a.0+(b.0-a.0)*t,y:a.1+(b.1-a.1)*t))}
            }
            if let b=vertices.last {samples.append(CGPoint(x:b.0,y:b.1))}
            let points=samples.enumerated().map { i,p in PKStrokePoint(location:p,timeOffset:Double(i)*0.006,size:CGSize(width:4,height:4),opacity:1,force:1,azimuth:0,altitude:.pi/2) }
            return PKStroke(ink:PKInk(.pen,color:UIColor(red:0.14,green:0.26,blue:0.23,alpha:1)),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
        }
        let hinge:XY=(260,290),r=90.0
        let arm=stroke([hinge,(hinge.0+r*cos(.pi/6),hinge.1-r*sin(.pi/6))])
        let lead=stroke([(350,290),(496,290),(496,316)])
        let filament=stroke([(482,358),(478,332),(491,344),(500,330),(511,343),(508,358)])
        let glass=(0...56).map { i->XY in let t=Double(i)/56;let a=2.25 + t*4.92;return (496+32*cos(a),341+32*sin(a)) }
        return PKDrawing(strokes:[arm,lead,filament,stroke(glass),stroke([(478,365),(514,365)]),stroke([(481,372),(511,372)]),stroke([(496,373),(496,432),(180,432),(180,371)]),stroke([(164,368),(196,368)]),stroke([(158,354),(202,354)]),stroke([(180,351),(180,290),hinge])])
    }
    @MainActor static func add(to studio:Studio) async throws -> UUID {
        let page=SheetPage(),paper=Paper(title:"Close the circuit",kind:.notebook,pages:[page])
        let group=Project(title:"Circuit lesson",entries:[.init(.paper,paper.id)])
        guard studio.change({ $0.papers.append(paper);$0.addProject(group) }) else {throw StudioError.unsafeLibrary}
        studio.saveInk(drawing(),paperID:paper.id,pageID:page.id)
        let polygon=[CGPoint(x:120,y:190),CGPoint(x:570,y:190),CGPoint(x:570,y:470),CGPoint(x:120,y:470)]
        guard let selection=try SketchSelection(polygon:polygon,studio:studio,paper:paper,page:page) else {throw StudioError.invalidPage}
        let scene=SketchScene(selection,group:[0],motion:.hinge,amount:30,wire:1,bulb:2)
        let file=UUID().uuidString+".gif",target=studio.assetFolder.appendingPathComponent(file)
        try FileManager.default.createDirectory(at:studio.assetFolder,withIntermediateDirectories:true)
        try await Task.detached { try scene.gif(to:target) }.value
        _=studio.editPage(paper.id,page.id) { $0.typed=narration;$0.visual=TeachingVisual(rect:selection.rect,caption:narration,filename:file) }
        return paper.id
    }
}
