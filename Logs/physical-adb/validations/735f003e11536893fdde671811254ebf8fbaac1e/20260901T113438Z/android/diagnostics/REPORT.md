# Army Attack Android validation

- TESTED_SHA: 735f003e11536893fdde671811254ebf8fbaac1e
- game version: 23.2
- published source: Valverde-101/Test_army_attack@306bccc7db5b1ce34dd68a3bc80093648c9224bd
- APK: V:\AndroidBuild\Builds\code-army-client\735f003e11536893fdde671811254ebf8fbaac1e\android\ArmyAttack-android-arm64-gpu.apk
- APK_SHA256: 4831929a0d8fdbb2d599d4781e761f4b95b9d91d2e75bf94c2083f24ba376388
- package: air.army.attack
- ABI: arm64-v8a
- targetSdk: 33
- SWF: assets/iArmyAirOfflineSavingv23.swf
- SWF_SHA256: 257c184fc00a4bd5db36d562315f29e1089e52bbbdb589db5a42655298532c2c
- SWF bytecode modified: True
- render mode: gpu
- native performance overlay: True
- profiler ANE SHA256: ab8541edf47f058e07e73d06586fb165f1df6620bea8852d9f119df8cb578cad
- build tier: HARMAN_AIR50_ARM64
- signature: PASS
- zipalign: PASS
- validation failures: 13
- failures: performance_patch_version=mobile-engine-v3.11-pvp-ui-mainmap-camera-culling; performance_patch_class_unexpected=com.dchoc.graphics.DCResourceManager; performance_patch_class_unexpected=com.dchoc.GUI.DCButton; performance_patch_class_unexpected=game.characters.PvPEnemyUnit; performance_patch_class_unexpected=game.gameElements.PlayerBuildingObject; performance_patch_class_unexpected=game.gameElements.HFEObject; performance_patch_class_unexpected=game.gameElements.LootReward; performance_patch_class_unexpected=game.actions.PvPAttackEnemyAction; performance_patch_class_unexpected=game.actions.PvPAttackEnemyInstallationAction; performance_patch_class_unexpected=game.actions.PvPFireMissionAction; performance_patch_class_unexpected=game.gui.GameHUD; performance_patch_class_unexpected=game.gui.pvp.PvPDebriefingDialog; performance_patch_class_count expected=15 actual=26

