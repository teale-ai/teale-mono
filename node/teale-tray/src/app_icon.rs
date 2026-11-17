//! Full-colour Teale app icon for the companion window (title bar, taskbar,
//! Alt-Tab). Pre-rendered from the teale.com favicon by
//! `node/scripts/make-app-icons.ps1`; shipping raw RGBA keeps an image
//! decoder out of the tray, like the tray's own leaf mask.

use tao::window::Icon;

#[cfg_attr(not(windows), allow(dead_code))]
const ICON_32: &[u8] = include_bytes!("../assets/teale-app-32.rgba");
const ICON_256: &[u8] = include_bytes!("../assets/teale-app-256.rgba");

/// 32x32, for the Windows title bar (`ICON_SMALL`).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn small() -> Option<Icon> {
    from_rgba(ICON_32, 32)
}

/// 256x256, for the Windows taskbar and Alt-Tab (`ICON_BIG`) and the Linux
/// window icon.
pub fn large() -> Option<Icon> {
    from_rgba(ICON_256, 256)
}

fn from_rgba(rgba: &[u8], size: u32) -> Option<Icon> {
    Icon::from_rgba(rgba.to_vec(), size, size).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icons_have_expected_dimensions() {
        assert_eq!(ICON_32.len(), 32 * 32 * 4);
        assert_eq!(ICON_256.len(), 256 * 256 * 4);
        assert!(small().is_some());
        assert!(large().is_some());
    }

    #[test]
    fn corners_are_transparent_and_centre_is_the_leaf() {
        // Top-left corner sits outside the rounded square.
        assert_eq!(ICON_256[3], 0);
        // Centre pixel is the opaque teal leaf (#1BC099 in the favicon).
        let centre = (128 * 256 + 128) * 4;
        assert_eq!(&ICON_256[centre..centre + 4], &[0x1b, 0xc0, 0x99, 0xff]);
    }
}
