import SwiftUI

// SwiftUI's @State also names an SDK 27 macro whose plugin is absent from Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
