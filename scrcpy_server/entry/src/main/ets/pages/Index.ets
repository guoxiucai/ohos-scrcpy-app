import { SCRCPY_PORT } from '../scrcpyservice/ScrcpyService';

@Entry
@Component
struct Index {
  build() {
    Column({ space: 16 }) {
      Text('OpenHarmony Scrcpy Server')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)

      Row({ space: 8 }) {
        Circle({ width: 12, height: 12 }).fill('#22c55e')
        Text('服务已自动运行').fontSize(14)
      }

      Text(`监听端口: 127.0.0.1:${SCRCPY_PORT}`)
        .fontSize(14)
        .opacity(0.7)

      Text('PC 端转发: hdc fport tcp:5005 tcp:53535')
        .fontSize(12)
        .opacity(0.5)

      Text('提示: ServiceExtension 由 keepAlive 接管，关闭本页面不会停止推流。')
        .fontSize(12)
        .opacity(0.5)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
