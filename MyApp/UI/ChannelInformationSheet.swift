import SwiftUI

struct ChannelInformationSheet: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ChannelLogo(url: channel.logoURL, name: channel.name, size: 80)
                    Text(ChannelDisplayName.make(from: channel.name).title)
                        .font(Theme.Typography.title)
                        .accessibilityAddTraits(.isHeader)
                    if let group = channel.group, !group.isEmpty {
                        Label(BroadcastPresentation.category(group), systemImage: "folder")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let quality = ChannelDisplayName.make(from: channel.name).quality {
                        LabeledContent("Stream quality", value: quality)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.screen)
            }
            .background(Theme.background)
            .navigationTitle("Channel details")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
