//
//  GraphView.swift
//  Sensors
//
//  Created by Linda Cobb on 9/22/14.
//  Copyright (c) 2014 TimesToCome Mobile. All rights reserved.
//

import Foundation
import UIKit


class GraphView: UIView
{
    
    // graph dimensions
    // put up here as globals so we only have to calculate them one time
    var area: CGRect!
    var maxPoints: Int!
    var height: CGFloat!
    var scale:Float = 1.0

    
    // incoming data to graph
    var dataArrayX:[CGFloat]!
    
    
    
    required init( coder aDecoder: NSCoder ){ super.init(coder: aDecoder) }
    
    override init(frame:CGRect){ super.init(frame:frame) }
    
    
    
    func setupGraphView() {
        
        area = frame
        maxPoints = Int(area.size.width)
        height = CGFloat(area.size.height)
        
        dataArrayX = [CGFloat](count:maxPoints, repeatedValue: 0.0)
        scale = Float(area.height) * 200
        
    }
    
    
    
    
    
    
    
    func addX(x: Float){
        
        
        // scale incoming data and insert it into data array
        let xScaled = CGFloat(x * scale % Float(height))
        
        dataArrayX.insert(xScaled, atIndex: 0)
        dataArrayX.removeLast()
        
        setNeedsDisplay()
    }
    
    
    
    override func drawRect(rect: CGRect) {
        
        let context = UIGraphicsGetCurrentContext()
        CGContextSetStrokeColor(context, [1.0, 0.0, 0.0, 1.0])
        
        for i in 1..<maxPoints {
            
            let mark = CGFloat(i)
            
            // plot x
            CGContextMoveToPoint(context, mark-1, self.dataArrayX[i-1] )
            CGContextAddLineToPoint(context, mark, self.dataArrayX[i] )
            
            CGContextSetLineWidth(context, 3.0)
            CGContextStrokePath(context)
                        
        }
    }
    
}









