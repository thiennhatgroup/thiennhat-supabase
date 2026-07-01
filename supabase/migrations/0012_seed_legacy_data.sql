-- ============================================================================
-- 0012_seed_legacy_data.sql
-- One-time import of legacy data from the Google Sheets workbook
-- 'File NVL mua hàng (1).xlsx': suppliers (DM_DOI_TUONG), materials
-- (DROPDOWN_LISTS + DATA_GIA), and 71 real price quotes (DATA_GIA).
-- Debts (DU_LIEU_CONG_NO) are intentionally NOT imported here: that sheet's
-- columns are misaligned vs its header and it is financial data, so it is
-- handled separately after explicit mapping confirmation.
-- Guarded by count()=0 checks so re-running the migration is a no-op.
-- ============================================================================

do $$
begin
  if (select count(*) from doi_tuong) = 0 then
    insert into doi_tuong (ma_doi_tuong, ten_doi_tuong, loai, mst, dia_chi, contact, dieu_khoan_tt_mac_dinh, trang_thai) values
      ('DT-0001', 'Công ty cổ phần đầu tư SK Việt Nam', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0002', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0003', 'Công ty CP Bachchambard Vĩnh Phúc', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0004', 'Công ty CP CK Vina (Hải Phòng)', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0005', 'Công ty CP dầu khí quốc tế PS', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0006', 'Công ty CP thiết bị Giao Thông (BEST)', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0007', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0008', 'Công ty CP vật tư Giao Thông (Tratimex)', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0009', 'Công ty CP VN Asphalt', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0010', 'Công ty CP XNK xăng dầu Bình Minh', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0011', 'Công ty CP Xuất Nhập khẩu Đăng Quang', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0012', 'Công ty Nhũ tương Việt Pháp', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0013', 'Công ty TNHH Bảo Khánh', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0014', 'Công ty TNHH khoáng sản Bảo Minh', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0015', 'Công ty TNHH nhựa đường Petrolimex', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0016', 'Công ty TNHH nhựa đường Petrolimex Nhũ trả tiền sau', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0017', 'Công ty TNHH nhựa đường Petrolimex Nhựa đường trả tiền trước', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0018', 'Công ty TNHH Tadashi', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0019', 'Dầu mỡ Thủ Đô', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0020', 'Xăng dầu Hồng Quân (Thiên Hà)', 'NCC', null, null, null, null, 'Hoạt động'),
      ('DT-0021', 'Xăng dầu Xuân Cương (Quang Cường)', 'NCC', null, null, null, null, 'Hoạt động');
  end if;

  if (select count(*) from materials) = 0 then
    insert into materials (ten, dvt) values
      ('Bột đá - CaCO3', 'vnđ/lít'),
      ('Dầu 20w-50', null),
      ('Dầu cầu hộp số 85W-140 Petro Japan (205l/phuy)', 'vnđ/lít'),
      ('Dầu cầu TITAN SuperGear 85W-140 (205l/phuy) - FUSCH', 'vnđ/lít'),
      ('Dầu Diesel', 'vnđ/lít'),
      ('Dầu DO 0,05S-II', 'vnđ/kg'),
      ('Dầu động cơ Fusch (205l/phuy)', null),
      ('Dầu động vơ, cầu, số, thủy lực, mỡ', null),
      ('Dầu đốt HFO 350', 'vnđ/lít'),
      ('Dầu thủy lực AW68 Petro Japan (200l/phuy)', 'vnđ/lít'),
      ('Dầu thủy lực Renolin B68 Plus (205l/phuy) - FUSCH', 'vnđ/lít'),
      ('Dầu truyền nhiệt Sinopec', null),
      ('Dầu truyền nhiệt Total seriola 1510', null),
      ('Dầu truyền nhiệt Total Seriola 1510', null),
      ('Dầu, mỡ các loại', null),
      ('Nhũ tương CRS-1', 'vnđ/kg'),
      ('Nhựa đường đặc 60/70 Đài Loan', 'vnđ/kg'),
      ('Nhựa đường đặc 60/70 Trung Quốc', 'vnđ/kg'),
      ('Nhựa đường lỏng mác MC 70', 'vnđ/kg'),
      ('Phụ gia', null),
      ('Tiền vận chuyển dầu', null);
  end if;

  if (select count(*) from price_quotes) = 0 then
    insert into price_quotes (ngay, ma, mat_hang, ncc, dvt, gia, vat_status, de_xuat, ghi_chu, nguon) values
      ('2026-05-14', '1', 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 17300.0, 'Chưa VAT', 'Có', 'Giao đến trạm. Thanh toán trước khi nhận hàng.', 'Legacy'),
      ('2026-05-14', '2', 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP VN Asphalt', 'vnđ/kg', 16960.0, 'Chưa VAT', 'Không', 'Thanh toán khi nhận được hóa đơn VAT.', 'Legacy'),
      ('2026-05-14', '5', 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP Xuất Nhập khẩu Đăng Quang', 'vnđ/kg', 16300.0, 'Chưa VAT', 'Không', 'Giao về Cao Dương - Hòa Bình, thanh toán trước.', 'Legacy'),
      ('2026-05-14', '6', 'Nhựa đường đặc 60/70 Đài Loan', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 17300.0, 'Chưa VAT', 'Không', 'Giao đến trạm Xuân Mai-Hòa Bình. Thanh toán trước. Tối thiểu 15 tấn.', 'Legacy'),
      ('2026-05-14', '7', 'Nhũ tương CRS-1', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 15500.0, 'Chưa VAT', 'Có', 'Giao đến trạm Phú Thọ. Thanh toán trước khi nhận hàng.', 'Legacy'),
      ('2026-05-14', '8', 'Nhũ tương CRS-1', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 12500.0, 'Chưa VAT', 'Không', 'Tối thiểu 5 tấn. Giá đã gồm phun tưới.', 'Legacy'),
      ('2026-05-14', '10', 'Nhựa đường lỏng mác MC 70', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 28300.0, 'Chưa VAT', 'Không', 'Giao đến trạm Phú Thọ. Bao gồm phun tưới.', 'Legacy'),
      ('2026-05-14', '11', 'Nhựa đường lỏng mác MC 70', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 26000.0, 'Chưa VAT', 'Không', 'Giao đến trạm Xuân Mai-Hòa Bình. Đã bao gồm phun tưới.', 'Legacy'),
      ('2026-05-14', '12', 'Dầu đốt HFO 350', 'Công ty CP XNK xăng dầu Bình Minh', 'vnđ/lít', 18000.0, 'Đã gồm VAT', 'Không', 'Đã gồm VAT, vận chuyển. Thanh toán sau khi giao hàng.', 'Legacy'),
      ('2026-05-14', '13', 'Dầu đốt HFO 350', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', 'vnđ/lít', 17900.0, 'Đã gồm VAT', 'Không', 'Đã gồm VAT, vận chuyển. Thanh toán sau khi giao hàng.', 'Legacy'),
      ('2026-05-16', '1', 'Nhựa đường đặc 60/70 Đài Loan', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 17300.0, 'Chưa VAT', 'Có', null, 'Legacy'),
      ('2026-05-16', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 17300.0, 'Chưa VAT', 'Có', null, 'Legacy'),
      ('2026-05-16', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP VN Asphalt', 'vnđ/kg', 16960.0, 'Chưa VAT', 'Có', null, 'Legacy'),
      ('2026-05-16', null, 'Dầu Diesel', 'Xăng dầu Xuân Cương (Quang Cường)', 'vnđ/lít', 27220.0, 'Đã gồm VAT', 'Có', null, 'Legacy'),
      ('2026-05-16', null, 'Dầu Diesel', 'Xăng dầu Hồng Quân (Thiên Hà)', 'vnđ/lít', 27220.0, 'Chưa VAT', 'Có', null, 'Legacy'),
      ('2026-05-16', null, 'Dầu 20w-50', 'Dầu mỡ Thủ Đô', null, 19656.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-16', null, 'Nhựa đường lỏng mác MC 70', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 26000.0, 'Chưa VAT', 'Có', 'Đã gồm phun tưới', 'Legacy'),
      ('2026-05-16', null, 'Nhựa đường đặc 60/70 Đài Loan', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 17300.0, 'Chưa VAT', 'Có', 'Cần thanh toán trước kèm công nợ kỳ trước', 'Legacy'),
      ('2026-05-16', null, 'Dầu đốt HFO 350', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', 'vnđ/lít', 17900.0, 'Đã gồm VAT', 'Có', 'Thanh toán nốt cùng công nợ', 'Legacy'),
      ('2026-05-16', null, 'Dầu DO 0,05S-II', 'Xăng dầu Xuân Cương (Quang Cường)', 'vnđ/kg', 27220.0, 'Đã gồm VAT', 'Không', 'Còn nợ lô đặt trước 572tr', 'Legacy'),
      ('2026-05-16', null, 'Dầu DO 0,05S-II', 'Xăng dầu Hồng Quân (Thiên Hà)', 'vnđ/kg', 27220.0, 'Đã gồm VAT', 'Không', null, 'Legacy'),
      ('2026-05-20', null, 'Dầu cầu TITAN SuperGear 85W-140 (205l/phuy) - FUSCH', 'Dầu mỡ Thủ Đô', 'vnđ/lít', 22500000.0, 'Đã gồm VAT', 'Không', 'Kho cách công ty 2km, đã gồm cước vận chuyển', 'Legacy'),
      ('2026-05-20', null, 'Dầu thủy lực Renolin B68 Plus (205l/phuy) - FUSCH', 'Dầu mỡ Thủ Đô', 'vnđ/lít', 16800000.0, 'Đã gồm VAT', 'Không', 'Kho cách công ty 2km, đã gồm cước vận chuyển', 'Legacy'),
      ('2026-05-20', null, 'Dầu cầu hộp số 85W-140 Petro Japan (205l/phuy)', 'Công ty TNHH Tadashi', 'vnđ/lít', 14722222.22, 'Đã gồm VAT', 'Không', 'Kho từ Thái Bình, giá đã gồm cước vận chuyển', 'Legacy'),
      ('2026-05-20', null, 'Dầu thủy lực AW68 Petro Japan (200l/phuy)', 'Công ty TNHH Tadashi', 'vnđ/lít', 12685185.19, 'Đã gồm VAT', 'Không', 'Kho từ Thái Bình, giá đã gồm cước vận chuyển', 'Legacy'),
      ('2026-05-24', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 17100.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-24', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP VN Asphalt', 'vnđ/kg', 16760.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-24', null, 'Nhựa đường lỏng mác MC 70', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 29800.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-24', null, 'Nhựa đường lỏng mác MC 70', 'CÔNG TY CP TM XNK VẬT TƯ HƯNG CƯỜNG', 'vnđ/kg', 26000.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-26', null, 'Nhũ tương CRS-1', 'Công ty Nhũ tương Việt Pháp', 'vnđ/kg', 16900.0, 'Chưa VAT', 'Không', 'Giá gồm cước vận chuyển và phun tưới', 'Legacy'),
      ('2026-05-26', null, 'Nhựa đường lỏng mác MC 70', 'Công ty Nhũ tương Việt Pháp', 'vnđ/kg', 28000.0, 'Chưa VAT', 'Không', 'Giá gồm cước vận chuyển và phun tưới', 'Legacy'),
      ('2026-05-26', null, 'Nhựa đường lỏng mác MC 70', 'Công ty TNHH nhựa đường Petrolimex', 'vnđ/kg', 29800.0, 'Chưa VAT', 'Không', 'Giá gồm cước vận chuyển và phun tưới', 'Legacy'),
      ('2026-05-26', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP vật tư Giao Thông (Tratimex)', 'vnđ/kg', 16650.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-27', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP vật tư Giao Thông (Tratimex)', 'vnđ/kg', 16350.0, 'Chưa VAT', 'Không', 'Gồm cước vận chuyển', 'Legacy'),
      ('2026-05-27', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP VN Asphalt', 'vnđ/kg', 16460.0, 'Chưa VAT', 'Không', 'Gồm cước vận chuyển', 'Legacy'),
      ('2026-05-29', null, 'Dầu đốt HFO 350', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', 'vnđ/lít', 18000.0, 'Đã gồm VAT', 'Không', 'Gồm cước vận chuyển tại trạm', 'Legacy'),
      ('2026-05-29', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP vật tư Giao Thông (Tratimex)', 'vnđ/kg', 16350.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-29', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP VN Asphalt', 'vnđ/kg', 16460.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-05-29', null, 'Dầu DO 0,05S-II', 'Xăng dầu Hồng Quân (Thiên Hà)', 'vnđ/kg', 26950.0, 'Đã gồm VAT', 'Không', null, 'Legacy'),
      ('2026-05-29', null, 'Dầu DO 0,05S-II', 'Xăng dầu Xuân Cương (Quang Cường)', 'vnđ/kg', 27100.0, 'Đã gồm VAT', 'Không', null, 'Legacy'),
      ('2026-06-01', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP VN Asphalt', 'vnđ/kg', 16460.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-02', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP thiết bị Giao Thông (BEST)', 'vnđ/kg', 16600.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-02', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP CK Vina (Hải Phòng)', 'vnđ/kg', 16400.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-02', null, 'Nhũ tương CRS-1', 'Công ty Nhũ tương Việt Pháp', 'vnđ/kg', 15550.0, 'Chưa VAT', 'Không', 'Giá gồm cước vận chuyển về trạm (2 tấn - giá VC 2tr1)', 'Legacy'),
      ('2026-06-02', null, 'Nhũ tương CRS-1', 'Công ty CP Bachchambard Vĩnh Phúc', 'vnđ/kg', 13500.0, 'Chưa VAT', 'Không', 'Giá gồm cước vận chuyển về trạm (2 tấn - giá VC 2tr)', 'Legacy'),
      ('2026-06-02', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP CK Vina (Hải Phòng)', 'vnđ/kg', 16400.0, 'Chưa VAT', 'Không', 'Đơn vị mới, chưa ký hợp đồng', 'Legacy'),
      ('2026-06-02', null, 'Nhựa đường đặc 60/70 Trung Quốc', 'Công ty CP thiết bị Giao Thông (BEST)', 'vnđ/kg', 16600.0, 'Chưa VAT', 'Không', 'Đã đặt đơn nhỏ lẻ từ 2025', 'Legacy'),
      ('2026-06-19', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP vật tư Giao Thông (Tratimex)', 'vnđ/kg', 17350.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Nhựa đường đặc 60/70 Đài Loan', 'Công ty CP VN Asphalt', 'vnđ/kg', 17400.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Dầu đốt HFO 350', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', 'vnđ/lít', 17500.0, 'Đã gồm VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Dầu đốt HFO 350', 'Công ty CP XNK xăng dầu Bình Minh', 'vnđ/lít', 16800.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Nhựa đường lỏng mác MC 70', 'Công ty Nhũ tương Việt Pháp', 'vnđ/kg', 27500.0, 'Chưa VAT', 'Không', 'Gia tai tram, chua kem cuoc van chuyen', 'Legacy'),
      ('2026-06-19', null, 'Dầu đốt HFO 350', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', 'vnđ/lít', 16800.0, 'Đã gồm VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Bột đá - CaCO3', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 15000.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Bột đá - CaCO3', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 11111.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-19', null, 'Dầu 20w-50', 'Công ty cổ phần đầu tư SK Việt Nam', null, 11.0, 'Chưa VAT', 'Không', null, 'Legacy'),
      ('2026-06-20', null, 'Bột đá - CaCO3', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 11.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Bột đá - CaCO3', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 11.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu 20w-50', 'Công ty CP Bachchambard Vĩnh Phúc', null, 4.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu cầu hộp số 85W-140 Petro Japan (205l/phuy)', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 2.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu đốt HFO 350', 'Công ty CP CK Vina (Hải Phòng)', 'vnđ/lít', 2.0, 'Chưa VAT', 'Có', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Bột đá - CaCO3', 'Công ty CP CK Vina (Hải Phòng)', 'vnđ/lít', 2.0, 'Chưa VAT', 'Có', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Bột đá - CaCO3', 'Công ty CP vật tư Giao Thông (Tratimex)', 'vnđ/lít', 5.0, 'Chưa VAT', 'Có', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Tiền vận chuyển dầu', 'Công ty cổ phần đầu tư SK Việt Nam', null, 16.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu Diesel', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 1.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu 20w-50', 'Công ty cổ phần đầu tư SK Việt Nam', null, 1.0, 'Chưa VAT', 'Có', ' | AppSheet user: vriens.gpt@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Bột đá - CaCO3', 'Công ty TNHH Tadashi', 'vnđ/lít', 1.0, 'Chưa VAT', 'Có', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu 20w-50', 'CÔNG TY CỔ PHẦN VẬT TƯ DẦU KHÍ HÀ NỘI', null, 100000000.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-20', null, 'Dầu Diesel', 'Xăng dầu Xuân Cương (Quang Cường)', 'vnđ/lít', 25350.0, 'Đã gồm VAT', 'Có', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-21', null, 'Bột đá - CaCO3', 'Công ty cổ phần đầu tư SK Việt Nam', 'vnđ/lít', 1.0, 'Chưa VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy'),
      ('2026-06-21', null, 'Dầu Diesel', 'Xăng dầu Xuân Cương (Quang Cường)', 'vnđ/lít', 110718.0, 'Đã gồm VAT', 'Không', ' | AppSheet user: ahuyle.work@gmail.com', 'Legacy');
  end if;
end $$;
