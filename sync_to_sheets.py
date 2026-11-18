#!/usr/bin/env python3
"""
어반사이드 POS 판매 데이터 → Google Sheets 동기화 스크립트
Supabase에서 판매 데이터를 읽어 Google Sheets에 동기화합니다.

실행: python sync_to_sheets.py
스케줄 실행: 가급적 하루 1~2회 (예: 판매 마감 후)
"""

import gspread
import json
from datetime import datetime, timedelta
import os
import sys

# Supabase 연결 (가정: environment variable 또는 직접 입력)
SB_URL = "https://owykoqnhwmdhpadxipes.supabase.co"
SB_KEY = "sb_publishable_Pgf79543Sk1FvB_PtWK5PA_2U9jlGbD"  # 공개용 키

# Google Sheets 설정
SHEET_ID = None  # 사용자가 입력할 Google Sheets ID
SHEET_NAME = "판매_주문내역"  # 동기화할 탭 이름

def get_supabase_sales():
    """Supabase에서 판매 데이터 조회"""
    import requests
    try:
        # 모든 판매 데이터 조회
        response = requests.get(
            f"{SB_URL}/rest/v1/pos_docs?path=ilike.s/%25/sales/%25",
            headers={"apikey": SB_KEY}
        )
        if response.status_code == 200:
            docs = response.json()
            # JSON 형식의 데이터 파싱
            sales = []
            for doc in docs:
                try:
                    data = json.loads(doc.get("data", "{}"))
                    sales.append({
                        "id": doc.get("id"),
                        "timestamp": data.get("ts", 0),
                        "orderNo": data.get("orderNo", ""),
                        "day": data.get("day", ""),
                        "qty": data.get("qty", 0),
                        "total": data.get("total", 0),
                        "paid": data.get("paid", 0),
                        "custName": data.get("custName", ""),
                        "custPhone": data.get("custPhone", ""),
                        "memo": data.get("memo", ""),
                        "items": data.get("items", []),
                    })
                except json.JSONDecodeError:
                    continue
            return sales
        else:
            print(f"❌ Supabase 조회 실패: {response.status_code}")
            return []
    except Exception as e:
        print(f"❌ Supabase 연결 오류: {e}")
        return []

def sync_to_google_sheets(sales_data):
    """Google Sheets에 판매 데이터 동기화"""
    if not SHEET_ID:
        print("❌ Google Sheets ID를 설정해주세요.")
        print(f"   SHEET_ID = '당신의_구글시트_ID' (파일 URL에서 추출)")
        return False

    try:
        # Google Sheets 인증
        gc = gspread.oauth(
            scopes=['https://www.googleapis.com/auth/spreadsheets', 'https://www.googleapis.com/auth/drive.readonly'],
            credentials_filename=os.path.expanduser('~/.gspread/jh_oauth_client.json'),
            authorized_user_filename=os.path.expanduser('~/.gspread/jh_authorized_user.json')
        )

        # 스프레드시트 열기
        sh = gc.open_by_key(SHEET_ID)

        # 탭이 없으면 생성
        try:
            ws = sh.worksheet(SHEET_NAME)
        except gspread.exceptions.WorksheetNotFound:
            ws = sh.add_worksheet(SHEET_NAME, rows=1000, cols=15)
            print(f"✅ 새 탭 생성: {SHEET_NAME}")

        # 헤더 설정 (첫 번째 행)
        headers = ["판매시각", "주문번호", "주문자", "연락처", "상품수", "판매금액", "실결제", "주문 메모", "상품 목록"]
        ws.update('A1:I1', [headers])

        # 데이터 준비 (최근 7일 데이터)
        cutoff_date = (datetime.now() - timedelta(days=7)).isoformat()
        recent_sales = [s for s in sales_data if s.get("timestamp", 0) > datetime.fromisoformat(cutoff_date.replace('Z', '+00:00')).timestamp() * 1000]

        rows = []
        for sale in sorted(recent_sales, key=lambda x: x.get("timestamp", 0), reverse=True):
            ts = datetime.fromtimestamp(sale.get("timestamp", 0) / 1000)
            items_str = "; ".join([f"{item.get('name', '')} {item.get('color', '')}/{item.get('size', '')} ×{item.get('qty', 1)}" for item in sale.get("items", [])])

            rows.append([
                ts.strftime("%Y-%m-%d %H:%M"),
                sale.get("orderNo", ""),
                sale.get("custName", ""),
                sale.get("custPhone", ""),
                sale.get("qty", 0),
                f"₩{sale.get('total', 0):,}",
                f"₩{sale.get('paid', 0):,}",
                sale.get("memo", ""),
                items_str,
            ])

        # 데이터 삽입 (기존 데이터 삭제 후 새로 삽입)
        if rows:
            ws.delete_rows(2, ws.row_count)  # 헤더 제외 모든 행 삭제
            ws.append_rows(rows)
            print(f"✅ {len(rows)}개 주문 동기화 완료")
        else:
            print("ℹ️ 동기화할 판매 데이터가 없습니다.")

        return True

    except Exception as e:
        print(f"❌ Google Sheets 동기화 오류: {e}")
        return False

def main():
    print("🔄 어반사이드 POS 판매 데이터 동기화 시작...")
    print(f"⏰ 시간: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    # Supabase에서 데이터 조회
    print("\n📡 Supabase에서 판매 데이터 조회 중...")
    sales = get_supabase_sales()

    if sales:
        print(f"✅ {len(sales)}개 주문 조회 완료")

        # Google Sheets에 동기화
        print("\n📝 Google Sheets 동기화 중...")
        if sync_to_google_sheets(sales):
            print("\n✅ 동기화 완료!")
        else:
            print("\n❌ 동기화 실패")
            sys.exit(1)
    else:
        print("⚠️ 조회된 판매 데이터가 없습니다.")
        sys.exit(1)

if __name__ == "__main__":
    main()
