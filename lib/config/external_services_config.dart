/// 个人构建是否完全使用用户配置的外部服务。
///
/// 官方合集、百度网盘和官方词典资源仍按现有路径工作；此开关只影响
/// AI 转录、复述评价以及登录/订阅前置条件。
const externalServicesOnly = bool.fromEnvironment(
  'EXTERNAL_SERVICES_ONLY',
  defaultValue: false,
);
