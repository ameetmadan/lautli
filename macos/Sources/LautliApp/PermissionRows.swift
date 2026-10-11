import SwiftUI

struct PermissionRow: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title).font(.headline)
                Text(permission.explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…") { permission.request() }
                    .accessibilityLabel("Allow \(permission.title)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
