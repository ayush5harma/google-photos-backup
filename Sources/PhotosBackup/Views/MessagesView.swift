import SwiftUI

/// STUB (foundation commit): the Messages archive piece replaces this file.
struct MessagesView: View {
    @Binding var section: AppSection

    var body: some View {
        ContentUnavailableView("Messages", systemImage: "message")
    }
}
