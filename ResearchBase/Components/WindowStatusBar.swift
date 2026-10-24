//
//  WindowStatusBar.swift
//  ResearchBase
//
//  Source of truth: docs/researchbase.html (.statusbar & .banner)
//  Shows statusbar at bottom and warning/error banners at top.
//

import SwiftUI

enum AppWindowStatus {
    case normal
    case empty
    case loading
    case offline
    case lowDisk
}

struct WindowStatusBar: View {
    var status: AppWindowStatus = .normal
    var themeName: String = "Lavender"
    
    var body: some View {
        HStack(spacing: 16) {
            // Status Dot + Text
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                
                Text(status == .offline ? "Offline" : "Library ready")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
            
            // Indexing status
            Text(status == .loading ? "Indexing 428 of 1,203…" : "Indexed")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
            
            // Backup status
            Text(status == .lowDisk ? "Backup paused" : "Backed up today 03:00")
                .font(RBFont.caption())
                .foregroundStyle(status == .lowDisk ? RBColor.warning : RBColor.mutedText)
            
            Spacer()
            
            // Capture Endpoint
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                Text("Capture 127.0.0.1:24680")
            }
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
            
            // Theme name
            Text(themeName.capitalized)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(RBColor.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RBColor.border)
                .frame(height: 1)
        }
    }
    
    private var statusDotColor: Color {
        switch status {
        case .offline: return RBColor.warning
        case .lowDisk: return RBColor.error
        default: return RBColor.success
        }
    }
}

struct WindowBannersView: View {
    var status: AppWindowStatus = .normal
    var onRetry: () -> Void = {}
    var onFreeSpace: () -> Void = {}
    
    var body: some View {
        VStack(spacing: 0) {
            if status == .offline {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(RBColor.warning)
                    
                    Text("\(Text("You’re offline.").font(RBFont.secondary(.semibold)).foregroundStyle(RBColor.primaryText)) \(Text("Lookups use saved answers. Everything else keeps working.").font(RBFont.secondary()).foregroundStyle(RBColor.secondaryText))")
                    
                    Spacer()
                    
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RBColor.warning.opacity(0.12))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(RBColor.border).frame(height: 1)
                }
            } else if status == .lowDisk {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(RBColor.error)
                    
                    Text("\(Text("Low disk space: 180 MB free.").font(RBFont.secondary(.semibold)).foregroundStyle(RBColor.primaryText)) \(Text("Backups and builds are paused so nothing is half-written. Your data is safe.").font(RBFont.secondary()).foregroundStyle(RBColor.secondaryText))")
                    
                    Spacer()
                    
                    Button("Free up space", action: onFreeSpace)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RBColor.error.opacity(0.12))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(RBColor.border).frame(height: 1)
                }
            }
        }
    }
}
