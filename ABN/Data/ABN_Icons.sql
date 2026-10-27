-- ===========================================================================
-- ABN_Icons.sql (modinfo UpdateIcons). PLAN 8. Owner: WP4.
-- ICON_<NotificationType> aliases into existing cells of ICON_ATLAS_NOTIFICATIONS
-- (pattern EFV\EFV\Data\EFV_Icons.sql). The notification panel falls back to
-- "ICON_" .. NotificationType (NotificationPanel.lua:25,793). No new textures.
-- Keep the cells in step with the Icon column of ABN_Notifications.sql.
-- ===========================================================================

INSERT INTO IconDefinitions (Name, Atlas, 'Index') VALUES
	('ICON_ABN_NOTIF_STARTED',      'ICON_ATLAS_NOTIFICATIONS', 11),   -- CONSIDER_RAZE_CITY
	('ICON_ABN_NOTIF_TICK',         'ICON_ATLAS_NOTIFICATIONS', 0),    -- GENERIC
	('ICON_ABN_NOTIF_CANCELLED',    'ICON_ATLAS_NOTIFICATIONS', 85),   -- DIPLO_DEAL_EXPIRED
	('ICON_ABN_NOTIF_AUTOCANCEL',   'ICON_ATLAS_NOTIFICATIONS', 110),  -- CITY_BESIEGED_BY_OTHER_PLAYER
	('ICON_ABN_NOTIF_REMOVED',      'ICON_ATLAS_NOTIFICATIONS', 59),   -- CITY_LOST
	('ICON_ABN_NOTIF_DEBUFF_ENDED', 'ICON_ATLAS_NOTIFICATIONS', 84);   -- DIPLOMATIC_PROMISE_TO_KEPT
