# weaknet —— macOS 一键弱网工具

基于 macOS 系统自带的 `dnctl`(dummynet)+ `pfctl`,对**整机全部流量**做限速 / 加延迟 / 丢包,一键在「弱网 / 正常」之间切换。无需安装任何第三方软件,常用于 App / 后端在弱网环境下的测试。

## 安装

```bash
git clone git@github.com:forrestshi1/weaknet.git（如果是本地文件夹则不用git clone）
cd weaknet
chmod +x weaknet.sh
```

## 用法

开启弱网(会申请一次 sudo 密码,改动网络需要 root):

```bash
./weaknet.sh on 3g
```

关闭,恢复正常网络:

```bash
./weaknet.sh off
```

其他命令:

```bash
./weaknet.sh list      # 列出所有档位
./weaknet.sh status    # 查看当前状态
./weaknet.sh custom 1Mbit/s 100 0.05   # 自定义:带宽 / 单向延迟(ms) / 丢包率
```

## 内置档位

| 档位 | 带宽 | RTT | 丢包 | 场景 |
|------|------|-----|------|------|
| `2g` | 50Kbit/s | ~600ms | 5% | 慢速 2G / GPRS |
| `edge` | 240Kbit/s | ~300ms | 2% | 2.5G EDGE |
| `3g` | 1Mbit/s | ~200ms | 1% | 普通 3G |
| `4g` | 10Mbit/s | ~80ms | 0.2% | 4G / LTE |
| `weakwifi` | 1Mbit/s | ~300ms | 5% | 弱 WiFi |
| `lossy` | 2Mbit/s | ~500ms | 20% | 高延迟高丢包 |
| `verybad` | 100Kbit/s | ~1000ms | 30% | 极端恶劣(几乎不可用) |

## 原理

- 用 `dnctl` 创建 dummynet 管道,配置带宽 / 延迟 / 丢包率。
- 用 `pfctl` 把整机进出流量导入该管道。载入时**保留**已有的 `/etc/pf.conf` 规则(仅追加一个 `weaknet` 锚点),`off` 时精确释放并还原,不会误关系统或其他程序开启的 pf。
- `delay` 是**单向**延迟,一来一回 RTT ≈ 2×,所以表中标注的是实际 RTT。

## 注意

- 仅支持 macOS(依赖系统自带的 dummynet / pf)。
- `on` / `off` 会真实改动当前网络,需要 sudo 权限。
- **loopback(lo0) 默认豁免**:自动化工具(Playwright CDP、本地 mock、调试端口)走
  127.0.0.1,若一并限速会污染测量结果,高丢包档甚至会打断控制通道。个别 macOS
  版本不认 `no dummynet` 语法,脚本会自动回退为「限速全部流量」并打印提示。
- 规则加载后会校验锚点里确实有 dummynet 规则,加载失败会**报错退出**,不会出现
  「显示已开启、实际没限速」的静默失效。
- 若个别 macOS 版本 pf 语法有差异导致报错,请提交 issue。

## License

[MIT](LICENSE) © forrest
