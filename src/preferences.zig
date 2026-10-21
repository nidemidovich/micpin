pub const Preferences = struct {
    /// Borrowed UID; its storage must outlive the listener.
    preferred_uid: []const u8,

    pub fn getPreferredUid(self: Preferences) []const u8 {
        return self.preferred_uid;
    }
};
