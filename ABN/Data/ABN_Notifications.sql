-- ===========================================================================
-- ABN_Notifications.sql (modinfo UpdateDatabase). PLAN 8; SPIKES S5. Owner: WP4.
--
-- One Types row (Kind KIND_NOTIFICATION) and one Notifications row per type.
-- Message and Summary are NULL: the text is looked up in gameplay at send time
-- (ABN_Notify.Flush) from LOC_<type>_MESSAGE / _SUMMARY, or from the _OWN and
-- _LOST variants named at the top of ABN_Notify.lua.
-- Column pattern: EFV\EFV\Data\EFV_Notifications.sql (checked against the
-- game schema). Icon names are shipped IconDefinitions; ABN_Icons.sql adds the
-- ICON_<type> aliases to the same atlas cells (the panel falls back to those).
--
-- Expiry (S5 result: a one-turn type clears at the next turn, the other stays):
--   TICK and DEBUFF_ENDED go to the owner only and expire at the end of the
--   turn they are sent in. The types other civs receive persist, so a hotseat
--   player who sees the turn later still finds them (SPIKES S5 fallback).
--
-- NotificationType       To                 Severity  Expires  Icon cell (ICON_ATLAS_NOTIFICATIONS)
-- ABN_NOTIF_STARTED      owner + met civs   MID       0        11  CONSIDER_RAZE_CITY
-- ABN_NOTIF_TICK         owner              LOW       1        0   GENERIC
-- ABN_NOTIF_CANCELLED    owner + met civs   MID       0        85  DIPLO_DEAL_EXPIRED
-- ABN_NOTIF_AUTOCANCEL   owner + met civs   HIGH      0        110 CITY_BESIEGED_BY_OTHER_PLAYER
-- ABN_NOTIF_REMOVED      owner + met civs   MID       0        59  CITY_LOST
-- ABN_NOTIF_DEBUFF_ENDED owner              LOW       1        84  DIPLOMATIC_PROMISE_TO_KEPT
-- AutoActivate is 0 everywhere (PLAN 8); the player clicks to centre on the plot.
-- ===========================================================================

INSERT INTO Types (Type, Kind) VALUES
	('ABN_NOTIF_STARTED',      'KIND_NOTIFICATION'),
	('ABN_NOTIF_TICK',         'KIND_NOTIFICATION'),
	('ABN_NOTIF_CANCELLED',    'KIND_NOTIFICATION'),
	('ABN_NOTIF_AUTOCANCEL',   'KIND_NOTIFICATION'),
	('ABN_NOTIF_REMOVED',      'KIND_NOTIFICATION'),
	('ABN_NOTIF_DEBUFF_ENDED', 'KIND_NOTIFICATION');

INSERT INTO Notifications (NotificationType, SeverityType, ExpiresEndOfTurn, AutoActivate, Icon) VALUES
	('ABN_NOTIF_STARTED',      'MID',  0, 0, 'ICON_NOTIFICATION_CONSIDER_RAZE_CITY'),
	('ABN_NOTIF_TICK',         'LOW',  1, 0, 'ICON_NOTIFICATION_GENERIC'),
	('ABN_NOTIF_CANCELLED',    'MID',  0, 0, 'ICON_NOTIFICATION_DIPLO_DEAL_EXPIRED'),
	('ABN_NOTIF_AUTOCANCEL',   'HIGH', 0, 0, 'ICON_NOTIFICATION_CITY_BESIEGED_BY_OTHER_PLAYER'),
	('ABN_NOTIF_REMOVED',      'MID',  0, 0, 'ICON_NOTIFICATION_CITY_LOST'),
	('ABN_NOTIF_DEBUFF_ENDED', 'LOW',  1, 0, 'ICON_NOTIFICATION_DIPLOMATIC_PROMISE_TO_KEPT');
