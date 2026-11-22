#pragma once

// 올리멕스 와이파이 HTTP OTA. C3/S3 와 같이 /version · /update (80번).
// USB는 최초·비상만. 웹소켓은 81번 그대로입니다.

void hubOtaBegin();
void hubOtaLoop();
