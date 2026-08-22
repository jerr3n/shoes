package util

// pieces of code that dont make it insufferable to write code

func Prepend[T any](s []T, v T) []T {
	return append([]T{v}, s...)
}
func PrependArray[T any](a1 []T, a2 []T) []T {
	return append(a2, a1...)
}

const (
	eot = "\x04"
	us  = "\x1f"
)

// uuid

//func InjectData(db *gorm.DB, jobid string, data []byte, expiration int64, cfg HTTPConfig, rbx RobloxAPIConfig, logger *zap.Logger) error {
//	newUuid := uuid.NewString()
//	result := db.Create(DataStorage{
//		JobID: jobid,
//		UUID:  newUuid,
//		Data:  nil,
//	})
//	if result.Error == nil {
//		sum := sha256.Sum256(data)
//		exp := time.Now().Unix() + expiration
//		packet := fmt.Sprintf("%s\x1f%s\x1f%d\x04", newUuid, hex.EncodeToString(sum[:]), exp)
//
//	} else {
//		return nil
//	}
//}
